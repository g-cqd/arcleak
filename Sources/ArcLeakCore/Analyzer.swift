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
    public func analyze(files: [String], cacheURL: URL? = nil) async -> AnalysisReport {
        let included = files.filter { !configuration.isExcluded(path: $0) }
        var cache = cacheURL.map(FactsCache.load(url:))
        let snapshot = cache ?? FactsCache()

        struct FileOutcome: Sendable {
            var facts: FileFacts?
            var fingerprint: String?
            var cacheHit = false
            var findings: [Finding] = []
            var degraded: AnalysisReport.DegradedFile?
        }

        let outcomes = await withTaskGroup(of: FileOutcome.self) { group in
            for path in included {
                group.addTask { [configuration] in
                    let data: Data
                    do {
                        data = try Self.read(path: path)
                    } catch {
                        return FileOutcome(
                            degraded: AnalysisReport.DegradedFile(
                                path: path,
                                detail: String(describing: error)
                            )
                        )
                    }
                    let fingerprint = FactsCache.fingerprint(of: data)

                    let facts: FileFacts
                    var cacheHit = false
                    if let cached = snapshot.facts(for: path, fingerprint: fingerprint) {
                        facts = cached
                        cacheHit = true
                    } else {
                        guard let source = String(data: data, encoding: .utf8) else {
                            return FileOutcome(
                                degraded: AnalysisReport.DegradedFile(
                                    path: path,
                                    detail: "not valid UTF-8"
                                )
                            )
                        }
                        facts = FactsExtraction.extract(path: path, source: source)
                    }
                    let findings = RuleEngine.check(file: facts, configuration: configuration)
                    return FileOutcome(
                        facts: facts,
                        fingerprint: fingerprint,
                        cacheHit: cacheHit,
                        findings: findings
                    )
                }
            }
            var collected: [FileOutcome] = []
            collected.reserveCapacity(included.count)
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
                corpus.append(facts)
                if let fingerprint = outcome.fingerprint {
                    cache?.update(path: facts.path, fingerprint: fingerprint, facts: facts)
                }
            }
            if outcome.cacheHit { hits += 1 }
            raw.append(contentsOf: outcome.findings)
            if let file = outcome.degraded {
                degraded.append(file)
            }
        }
        corpus.sort { $0.path < $1.path }
        raw.append(contentsOf: RuleEngine.checkCorpus(corpus: corpus, configuration: configuration))

        if let cache, let cacheURL {
            cache.persist(url: cacheURL)
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
        path: String
    ) -> (findings: [Finding], suppressed: [AnalysisReport.SuppressedFinding]) {
        let facts = FactsExtraction.extract(path: path, source: source)
        var raw = RuleEngine.check(file: facts, configuration: configuration)
        raw.append(contentsOf: RuleEngine.checkCorpus(corpus: [facts], configuration: configuration))
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

    private static func read(path: String) throws(ArcLeakError) -> Data {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .fileUnreadable(path: path, underlying: String(describing: error))
        }
        guard data.count <= maxFileBytes else {
            throw .fileUnreadable(path: path, underlying: "exceeds \(maxFileBytes) byte cap")
        }
        return data
    }
}
