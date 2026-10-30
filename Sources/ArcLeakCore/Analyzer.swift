public import CorpusScan
public import ProjectModel
import SourceCorpus
import SwiftParser

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
    /// With `cache`, per-file facts are reused through analyzerkit's `CorpusScanner` (ADR-0011) when this build
    /// wrote them and the file's content and the `#if` configuration match (parsing dominates runtime; rules always
    /// re-run, so findings can never go stale relative to rules or configuration).
    /// - Parameter reportScope: narrows the *report* to a set of files; nil reports everything.
    ///   The corpus is always analyzed whole: `mutual-strong-properties` walks an ownership graph
    ///   built from every type, so dropping the files a cycle passes through would erase the cycle.
    ///   A finding is kept when its anchor or any related location is in scope, because a cycle
    ///   anchors at an arbitrary link, so a pull request that closes it must see it in whichever
    ///   file the anchor landed. Contract: ``ProjectModel/ReportScope``.
    /// - Parameter projectFiles: Xcode projects, package manifests,
    ///   Info.plists, storyboards and xibs: they give the platforms `#if`
    ///   evaluates and the classes the system creates.
    public func analyze(
        files: [String],
        projectFiles: [String] = [],
        cache: CacheLocation? = nil,
        index: (any IndexReading)? = nil,
        reportScope: ReportScope? = nil
    ) async -> AnalysisReport {
        // Canonicalize before anything reads a path: `Finding.path` feeds the
        // fingerprint, and the corpus must not contain the same file twice
        // under two spellings (it would give the ownership graph two nodes for
        // one type). Exclusion is checked on the canonical form.
        let exclusion = configuration.pathFilter
        let included = SourcePath.canonicalized(files).filter { !exclusion.excludes($0) }
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
        let project = Self.projectFacts(from: projectFiles)
        let platforms = configuration.platforms.map { Set($0) } ?? project.platforms
        let definesSalt =
            configuration.activeDefines.sorted().joined(separator: ",") + "|" + contractSalt
            + "|os=" + platforms.sorted().joined(separator: ",")

        // Regions come from the project first (ADR-0024). The cache keeps only what the content says of a file's
        // region; the project's part changes without the file changing, so it is joined on every run.
        let started = ContinuousClock.now
        let classification =
            ProjectLayout.discover(paths: included).map(ProjectClassification.load) ?? .conventionsOnly
        let scan: CorpusScan<ExtractedFacts>
        do {
            scan = try await CorpusScanner.scan(
                paths: included, cache: cache,
                identity: CacheIdentity.current(tool: ToolInfo.name, version: ToolInfo.version), salt: definesSalt
            ) { [configuration] path, bytes in
                Self.extract(
                    bytes: bytes, path: path, configuration: configuration, platforms: platforms)
            }
        } catch {
            var cancelled = AnalysisReport()
            cancelled.wasCancelled = true
            return cancelled
        }
        let scanned = ContinuousClock.now

        // The per-file rules run on every run, from cached facts or fresh ones; a sliding window of `width` keeps
        // peak memory bounded. Rules recurse once per level of a syntax tree they hold: large stack (roadmap 0041).
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let entryPoints = project.systemEntryPoints
        let outcomes = await withTaskGroup(of: FileOutcome.self) { group in
            var collected: [FileOutcome] = []
            collected.reserveCapacity(scan.files.count)
            var scheduled = 0
            for file in scan.files {
                if Task.isCancelled { break }
                if scheduled >= width, let done = await group.next() { collected.append(done) }
                group.addTask { [configuration] in
                    await LargeStack.run {
                        Self.makeOutcome(
                            file: file, classification: classification, configuration: configuration,
                            systemEntryPoints: entryPoints)
                    }
                }
                scheduled += 1
            }
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        let corpusIndex = index.map {
            CorpusFirstIndex(base: $0, declared: CorpusFirstIndex.declaredTypeNames(in: outcomes.compactMap(\.facts)))
        }
        var corpus: [FileFacts] = []
        var raw: [Finding] = []
        var degraded: [AnalysisReport.DegradedFile] = []
        var hits = 0
        for var outcome in outcomes {
            if let corpusIndex, let facts = outcome.facts, facts.extendsUnknownType {
                // A file that extends a type the corpus does not declare: what the index knows of that type may
                // reach rules the per-file pass ran without it. The index parses declaring files: large stack.
                let entryPoints = project.systemEntryPoints
                let (effective, findings) = await LargeStack.run { [configuration] in
                    let effective = facts.upgraded(with: corpusIndex)
                    let findings = RuleEngine.check(
                        file: effective, configuration: configuration, systemEntryPoints: entryPoints)
                    return (effective, findings)
                }
                outcome.effectiveFacts = effective
                outcome.findings = findings
            }
            if let facts = outcome.facts {
                corpus.append(outcome.effectiveFacts ?? facts)
            }
            if outcome.cacheHit, outcome.facts != nil { hits += 1 }
            raw.append(contentsOf: outcome.findings)
            if let file = outcome.degraded {
                degraded.append(file)
            }
        }
        corpus.sort { $0.path < $1.path }
        let corpusFacts = corpus
        raw.append(
            contentsOf: await LargeStack.run { [configuration] in
                RuleEngine.checkCorpus(corpus: corpusFacts, configuration: configuration, index: corpusIndex)
            })

        // A cancelled run analysed only part of the corpus, and
        // `mutual-strong-properties` draws its conclusion from the whole of it.
        // Report nothing rather than something wrong.
        if Task.isCancelled {
            var cancelled = AnalysisReport()
            cancelled.wasCancelled = true
            return cancelled
        }

        var report = Self.assemble(
            raw: raw, corpus: corpus, reportScope: reportScope, regionSelection: regionSelection)

        // Anchor fingerprints to the repository, not to this machine's checkout
        // path or to whether the caller remembered --relative-to. Display is a
        // separate concern, handled by PathPresentation.
        if let root = RepositoryRoot.common(of: corpus.map(\.path)) {
            report = report.fingerprintsAnchored(to: root)
        }
        report.analyzedFileCount = included.count
        report.degradedFiles = degraded.sorted { $0.path < $1.path }
        // Over the files analysed, with or without a cache, as before analyzerkit's cache: a run without one misses
        // every file, and a file that was not analysed is no hit even when the cache remembers why.
        report.cacheHits = hits
        report.cacheMisses = corpus.count - hits
        report.cacheLoadFailure = scan.cacheLoadFailure
        report.classificationIssues = classification.issues(for: included)
        report.timings = [
            "scan": Self.seconds(scanned - started), "rules": Self.seconds(ContinuousClock.now - scanned),
        ]
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
            platforms: Set(configuration.platforms ?? []),
            contracts: configuration.contracts ?? []
        )
        let corpusIndex = index.map {
            CorpusFirstIndex(base: $0, declared: CorpusFirstIndex.declaredTypeNames(in: [facts]))
        }
        if let corpusIndex {
            facts = facts.upgraded(with: corpusIndex)
        }
        var raw = RuleEngine.check(file: facts, configuration: configuration)
        raw.append(
            contentsOf: RuleEngine.checkCorpus(
                corpus: [facts], configuration: configuration, index: corpusIndex
            )
        )
        let report = Self.assemble(raw: raw, corpus: [facts], regionSelection: regionSelection)
        return (report.findings, report.suppressed)
    }

    /// The parsed `--include`/`--exclude` selection; `Configuration.load`
    /// already validated it, so this can only fail for a `Configuration`
    /// built by hand with a bogus region name, and it fails open rather than
    /// making a rejected name analyze nothing.
    private var regionSelection: RegionSelection {
        (try? configuration.regionSelection()) ?? .none
    }

    private static func assemble(
        raw: [Finding], corpus: [FileFacts], reportScope: ReportScope? = nil,
        regionSelection: RegionSelection = .none
    ) -> AnalysisReport {
        let tables = Dictionary(
            corpus.map { ($0.path, SuppressionTable(directives: $0.directives)) },
            uniquingKeysWith: { first, _ in first }
        )
        let factsByPath = Dictionary(corpus.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        var report = AnalysisReport()
        for rawFinding in raw {
            let facts = factsByPath[rawFinding.path]
            if let reason = ProjectContext.withholdingReason(
                for: rawFinding, in: facts, regionSelection: regionSelection)
            {
                report.suppressed.append(AnalysisReport.SuppressedFinding(finding: rawFinding, reason: reason))
                continue
            }
            let finding = ProjectContext.annotated(rawFinding, in: facts, regionSelection: regionSelection)
            if let reason = tables[finding.path]?.suppression(for: finding.rule, line: finding.line) {
                report.suppressed.append(
                    AnalysisReport.SuppressedFinding(finding: finding, reason: reason)
                )
            } else if let reportScope, !reportScope.contains(finding) {
                // Kept, not dropped: the count stays visible in the summary and
                // `--format json` still carries them. Scope is applied after
                // suppression so suppression debt keeps counting the whole
                // corpus.
                report.outOfScope.append(finding)
            } else {
                report.findings.append(finding)
            }
        }
        report.findings.sort()
        report.outOfScope.sort()
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

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// One file's extraction as the cache stores it: the facts, or why the file was not analysed (over the size cap,
    /// not UTF-8, nested too deeply), so a cached file is never parsed again only to fail again. The facts' test and
    /// generated flags hold what the content alone says; ``makeOutcome`` joins the project's part.
    static func extract(
        bytes: [UInt8], path: String, configuration: Configuration, platforms: Set<String>
    ) -> ExtractedFacts {
        guard bytes.count <= maxFileBytes else {
            return ExtractedFacts(
                degraded: ArcLeakError.fileUnreadable(path: path, underlying: "exceeds \(maxFileBytes) byte cap")
                    .description)
        }
        // A byte-order mark is not source: columns count from after it, as SARIF's do (§3.30.2).
        let text = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
        guard let source = String(validating: text, as: UTF8.self) else {
            return ExtractedFacts(degraded: "not valid UTF-8")
        }
        let tree = Parser.parse(source: source)
        // Every walk of the tree recurses once per level; past the limit the file is listed, not walked.
        guard !SyntaxDepth.exceeds(tree) else {
            return ExtractedFacts(degraded: "nested deeper than \(SyntaxDepth.defaultLimit) levels; not analysed")
        }
        var facts = FactsExtraction.extract(
            path: path, tree: tree, defines: configuration.activeDefines, platforms: platforms,
            contracts: configuration.contracts ?? [])
        let content = ProjectClassification.contentRegion(path: path, tree: tree)
        facts.isTestCode = content.contains(.test)
        facts.isGenerated = content.contains(.generated)
        return ExtractedFacts(facts: facts)
    }

    /// The per-file rules over one scanned file, its region joined with what its project says.
    static func makeOutcome(
        file: ScannedFile<ExtractedFacts>, classification: ProjectClassification, configuration: Configuration,
        systemEntryPoints: Set<String>
    ) -> FileOutcome {
        if let failure = file.failure {
            return FileOutcome(
                degraded: AnalysisReport.DegradedFile(
                    path: file.path,
                    detail: ArcLeakError.fileUnreadable(path: file.path, underlying: failure).description))
        }
        guard let extracted = file.facts else { return FileOutcome() }
        guard var facts = extracted.facts else {
            return FileOutcome(
                degraded: AnalysisReport.DegradedFile(path: file.path, detail: extracted.degraded ?? "not analysed"))
        }
        var content: CodeRegion = []
        if facts.isTestCode { content.insert(.test) }
        if facts.isGenerated { content.insert(.generated) }
        let region = classification.classify(file.path, content: content).region
        facts.isTestCode = region.contains(.test)
        facts.isGenerated = region.contains(.generated)
        let findings = RuleEngine.check(
            file: facts, configuration: configuration, systemEntryPoints: systemEntryPoints)
        return FileOutcome(
            facts: facts, effectiveFacts: facts, fingerprint: file.fingerprint, cacheHit: file.cacheHit,
            findings: findings)
    }

    /// What the project files say: the platforms the project builds for,
    /// and the classes the system creates. An unreadable file says nothing.
    static func projectFacts(from projectFiles: [String]) -> (platforms: Set<String>, systemEntryPoints: Set<String>) {
        var platforms: Set<String> = []
        var entryPoints: Set<String> = []
        for path in projectFiles {
            guard let data = try? read(path: path) else { continue }
            let contents = String(decoding: data, as: UTF8.self)
            platforms.formUnion(ProjectPlatforms.platforms(path: path, contents: contents))
            for entryPoint in SystemEntryPoints.scan(path: path, contents: contents) {
                entryPoints.insert(entryPoint.typeName)
            }
        }
        return (platforms, entryPoints)
    }

    private static func read(path: String) throws(ArcLeakError) -> Data {
        let url = URL(fileURLWithPath: path)
        // Stat BEFORE reading: the size cap must reject a 4 GB file (or a
        // fifo/device masquerading as a source file) before it is pulled into
        // RAM. `Data(contentsOf:)` would OOM first if we checked count after.
        // `FileManager.attributesOfItem` rather than `URL.resourceValues`: the
        // two are equivalent here — same type and size, and neither traverses a
        // symlink, so a linked source is still refused as "not a regular file" —
        // but only this one is available in FoundationEssentials. Keeping the
        // hot read path off corelibs-only API is what would let arcleak drop
        // Foundation (and ~51 MiB of ICU on Linux) once its LSP server no longer
        // needs dynamic JSON. NOT a performance change: A/B over 1,981 files put
        // both at 0.57 s wall and ~2.7 s CPU, indistinguishable.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard (attributes?[.type] as? FileAttributeType) == .typeRegular else {
            throw .fileUnreadable(path: path, underlying: "not a regular file")
        }
        if let size = attributes?[.size] as? Int, size > maxFileBytes {
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
