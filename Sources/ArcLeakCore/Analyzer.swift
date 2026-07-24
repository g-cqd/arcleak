public import Foundation

/// Front door of the library. Three phases:
///
/// 1. Per-file (parallel, one task per file): read → parse → extract `FileFacts`
///    → per-file rules. Trees never cross task boundaries; only `Sendable`
///    facts and findings do.
/// 2. Corpus: cross-file rules (ownership graph / cycle SCCs) over all facts,
///    sorted by path so completion order can't affect output.
/// 3. Suppression + assembly: directives are applied per finding via its
///    file's table — corpus findings are suppressible exactly like local ones.
public struct Analyzer: Sendable {
    /// Files larger than this are skipped and reported as degraded rather than
    /// letting adversarial input balloon memory.
    public static let maxFileBytes = 10 * 1024 * 1024

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Analyzes explicit file paths. Input order does not affect output.
    ///
    /// With `cacheURL`, per-file facts are reused when the file's content
    /// fingerprint matches (parsing dominates runtime; rules always re-run, so
    /// findings can never go stale relative to rules or configuration).
    public func analyze(
        files: [String],
        cacheURL: URL? = nil,
        index: (any IndexReading)? = nil
    ) async -> AnalysisReport {
        let included = files.filter { !configuration.isExcluded(path: $0) }
        // `snapshot` serves cache hits (all historical entries); the persisted
        // cache is rebuilt from ONLY this run's files, so it stays shaped to the
        // project and never grows without bound in a shifting monorepo.
        let snapshot = cacheURL.map(FactsCache.load(url:)) ?? FactsCache()
        var freshCache = FactsCache()
        // Facts depend on the `#if` configuration and user contracts — salt
        // fingerprints so neither can serve stale facts. The full contract
        // identity (callee, base, template, required labels) enters the salt:
        // flipping a contract's template `tokenProducer` → `sinkWrapper` must
        // re-extract, not reuse facts keyed only by callee.
        let contractSalt = (configuration.contracts ?? [])
            .map {
                "\($0.callee)~\($0.base ?? "")~\($0.template.rawValue)"
                    + "~\(($0.requiredLabels ?? []).joined(separator: "+"))"
            }
            .sorted()
            .joined(separator: ",")
        let definesSalt =
            configuration.activeDefines.sorted().joined(separator: ",") + "|" + contractSalt

        // Bounded fan-out: one blocking read + parse per file would otherwise
        // spawn `included.count` tasks that block the (core-count-sized)
        // cooperative pool on I/O and hold every file's Data+tree in flight at
        // once. A sliding window caps concurrency, descriptor pressure, and
        // peak memory. `analyze` is cancellation-aware: a cancelled host stops
        // scheduling new files.
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount)

        let outcomes = await withTaskGroup(of: FileOutcome.self) { group in
            var collected: [FileOutcome] = []
            collected.reserveCapacity(included.count)
            var scheduled = 0
            for path in included {
                if Task.isCancelled { break }
                // Sliding window: keep at most `width` tasks in flight, draining
                // one before scheduling the next.
                if scheduled >= width {
                    if let done = await group.next() { collected.append(done) }
                }
                group.addTask { [configuration] in
                    Self.makeOutcome(
                        path: path,
                        snapshot: snapshot,
                        index: index,
                        configuration: configuration,
                        definesSalt: definesSalt
                    )
                }
                scheduled += 1
            }
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        var corpus: [FileFacts] = []
        var raw: [Finding] = []
        var degraded: [AnalysisReport.DegradedFile] = []
        var hits = 0
        for outcome in outcomes {
            if let facts = outcome.facts {
                corpus.append(outcome.effectiveFacts ?? facts)
                if let fingerprint = outcome.fingerprint {
                    freshCache.update(path: facts.path, fingerprint: fingerprint, facts: facts)
                }
            }
            if outcome.cacheHit { hits += 1 }
            raw.append(contentsOf: outcome.findings)
            if let file = outcome.degraded {
                degraded.append(file)
            }
        }
        corpus.sort { $0.path < $1.path }
        raw.append(
            contentsOf: RuleEngine.checkCorpus(
                corpus: corpus, configuration: configuration, index: index
            )
        )

        if let cacheURL {
            freshCache.persist(url: cacheURL)
        }

        var report = Self.assemble(raw: raw, corpus: corpus)
        report.analyzedFileCount = included.count
        report.degradedFiles = degraded.sorted { $0.path < $1.path }
        report.cacheHits = hits
        report.cacheMisses = corpus.count - hits
        return report
    }

    /// Analyzes one in-memory source (corpus of one). Synchronous; used by
    /// tests and stdin mode. Cross-file rules still run — two types in one
    /// file can close a cycle.
    public func analyze(
        source: String,
        path: String,
        index: (any IndexReading)? = nil
    ) -> (findings: [Finding], suppressed: [AnalysisReport.SuppressedFinding]) {
        var facts = FactsExtraction.extract(
            path: path,
            source: source,
            defines: configuration.activeDefines,
            contracts: configuration.contracts ?? []
        )
        if let index {
            facts = facts.upgraded(with: index)
        }
        var raw = RuleEngine.check(file: facts, configuration: configuration)
        raw.append(
            contentsOf: RuleEngine.checkCorpus(
                corpus: [facts], configuration: configuration, index: index
            )
        )
        let report = Self.assemble(raw: raw, corpus: [facts])
        return (report.findings, report.suppressed)
    }

    private static func assemble(raw: [Finding], corpus: [FileFacts]) -> AnalysisReport {
        let tables = Dictionary(
            corpus.map { ($0.path, SuppressionTable(directives: $0.directives)) },
            uniquingKeysWith: { first, _ in first }
        )

        var report = AnalysisReport()
        for finding in raw {
            if let reason = tables[finding.path]?.suppression(for: finding.rule, line: finding.line) {
                report.suppressed.append(
                    AnalysisReport.SuppressedFinding(finding: finding, reason: reason)
                )
            } else {
                report.findings.append(finding)
            }
        }
        report.findings.sort()
        report.suppressed.sort { $0.finding < $1.finding }
        return report
    }

    /// Per-file work result — value type so it crosses task boundaries freely.
    struct FileOutcome: Sendable {
        var facts: FileFacts?
        var effectiveFacts: FileFacts?
        var fingerprint: String?
        var cacheHit = false
        var findings: [Finding] = []
        var degraded: AnalysisReport.DegradedFile?
    }

    /// Reads, fingerprints, extracts (or reuses cached facts), and runs the
    /// per-file rules. All parameters are `Sendable`, so this is safe to call
    /// from a task-group child.
    static func makeOutcome(
        path: String,
        snapshot: FactsCache,
        index: (any IndexReading)?,
        configuration: Configuration,
        definesSalt: String
    ) -> FileOutcome {
        let data: Data
        do {
            data = try read(path: path)
        } catch {
            return FileOutcome(
                degraded: AnalysisReport.DegradedFile(path: path, detail: String(describing: error))
            )
        }
        let fingerprint = FactsCache.fingerprint(of: data, salt: definesSalt)

        let facts: FileFacts
        var cacheHit = false
        if let cached = snapshot.facts(for: path, fingerprint: fingerprint) {
            facts = cached
            cacheHit = true
        } else {
            guard let source = String(data: data, encoding: .utf8) else {
                return FileOutcome(
                    degraded: AnalysisReport.DegradedFile(path: path, detail: "not valid UTF-8")
                )
            }
            facts = FactsExtraction.extract(
                path: path,
                source: source,
                defines: configuration.activeDefines,
                contracts: configuration.contracts ?? []
            )
        }
        let effective = index.map { facts.upgraded(with: $0) } ?? facts
        let findings = RuleEngine.check(file: effective, configuration: configuration)
        return FileOutcome(
            facts: facts,
            effectiveFacts: effective,
            fingerprint: fingerprint,
            cacheHit: cacheHit,
            findings: findings
        )
    }

    private static func read(path: String) throws(ArcLeakError) -> Data {
        let url = URL(fileURLWithPath: path)
        // Stat BEFORE reading: the size cap must reject a 4 GB file (or a
        // fifo/device masquerading as a source file) before it is pulled into
        // RAM. `Data(contentsOf:)` would OOM first if we checked count after.
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else {
            throw .fileUnreadable(path: path, underlying: "not a regular file")
        }
        if let size = values?.fileSize, size > maxFileBytes {
            throw .fileUnreadable(path: path, underlying: "exceeds \(maxFileBytes) byte cap")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .fileUnreadable(path: path, underlying: String(describing: error))
        }
        // Defense in depth: a growing/lying file could still exceed the cap.
        guard data.count <= maxFileBytes else {
            throw .fileUnreadable(path: path, underlying: "exceeds \(maxFileBytes) byte cap")
        }
        return data
    }
}
