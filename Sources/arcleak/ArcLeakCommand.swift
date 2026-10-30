import AnalyzerCLI
import AnalyzerConfiguration
import ArcLeakCore
public import ArgumentParser
import CorpusScan
import ProjectModel
import ReportSupport
import SourceCorpus
import SystemPackage

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Stand-in for `FileHandle.standardError`, which lives in corelibs Foundation:
/// linking it would re-link ~47 MiB of ICU into every Linux binary. Keeps the
/// `.write(Data(...))` shape of the call sites so nothing else changes.
private struct StandardErrorHandle {
    func write(_ bytes: Data) {
        _ = try? FileDescriptor.standardError.writeAll(bytes)
    }
}

private let standardError = StandardErrorHandle()

@main
struct ArcLeakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ToolInfo.name,
        abstract: "Static ARC analysis for Swift: retain cycles, anchor leaks, premature releases.",
        version: ToolInfo.version,
        subcommands: [Analyze.self, Rules.self, Lsp.self],
        defaultSubcommand: Analyze.self
    )
}

struct Lsp: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run as a minimal LSP server over stdio (diagnostics + deliberate-suppression code actions)."
    )

    func run() throws {
        try LspServer.run()
    }
}

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze Swift files or directories (default: current directory)."
    )

    // analyzerkit's shared option groups (ADR-0019), in order; arcleak's own options after them.
    @OptionGroup(title: OptionGroupTitle.input) var input: InputOptions
    @OptionGroup(title: OptionGroupTitle.output) var output: OutputOptions
    @OptionGroup(title: OptionGroupTitle.rules) var rules: RuleOptions
    @OptionGroup(title: OptionGroupTitle.cache) var cache: CacheOptions
    @OptionGroup(title: OptionGroupTitle.index) var index: IndexOptions
    @OptionGroup(title: OptionGroupTitle.experimental) var experimental: ExperimentalOptions

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Write an empty stamp file after a successful (non-failing) run.",
            discussion:
                "Used by the build-tool plugin so the build system can skip re-analysis when inputs are unchanged."
        )
    )
    var stamp: String?

    @Flag(name: .long, help: "Apply mechanical [weak self] fix-its for fixable findings, in place.")
    var fix = false

    @Flag(
        name: .customLong("fix-dry-run"),
        help: "Report what --fix would change without writing files."
    )
    var fixDryRun = false

    @Flag(
        name: .customLong("experimental-sil-confirm"),
        help:
            "Verify stored-closure captures against SILGen; positively refuted findings are dropped (single-file, SDK-imports-only; fails open)."
    )
    var experimentalSilConfirm = false

    func run() async throws {
        for deprecation in input.deprecations + experimental.deprecations {
            note(deprecation.message(tool: ToolInfo.name))
        }
        // Read before the analysis, so a bad path fails with 78 without the analysis cost.
        var newSinceBaseline: Baseline?
        if let path = output.reportNewSince {
            newSinceBaseline = try baselineOrExit { try Baseline.load(path: path) }
        }
        var configuration = try loadConfiguration()
        if !input.defines.isEmpty {
            configuration.defines = (configuration.defines ?? []) + input.defines
        }
        if let include = input.includeRegions {
            configuration.includeRegions = include
        }
        if let exclude = input.excludeRegions {
            configuration.excludeRegions = exclude
        }
        try applyRules(to: &configuration)
        do {
            _ = try configuration.regionSelection()
        } catch {
            throw ValidationError(error.description)
        }
        let (files, projectFiles) = try discoverInputs(configuration: configuration)
        guard !files.isEmpty else {
            throw ValidationError(ArcLeakError.noInputs.description)
        }

        let index = await resolveIndex(files: files, configuration: configuration)

        let reportScope = try resolveReportScope()
        // A non-empty scope that intersects zero corpus files is almost always a
        // misconfiguration (paths relative to the wrong directory, wrong workdir),
        // and it silently reports nothing. Warn loudly; an *empty* scope stays
        // silent — "no Swift changed" is legitimate. The corpus is canonicalized
        // the way the scope is, so a path spelled through a symlink still matches.
        if output.reportNewSince == nil, let scope = reportScope, !scope.files.isEmpty,
            ReportScope(files: files).files.isDisjoint(with: scope.files)
        {
            standardError.write(
                Data(
                    "arcleak: warning: --only scope matches no analyzed file — check that scope paths are relative to the right directory\n"
                        .utf8))
        }

        var report = await Analyzer(configuration: configuration)
            .analyze(
                files: files, projectFiles: projectFiles, cache: cacheLocation(), index: index,
                reportScope: reportScope
            )
        // Once: the run rewrites the cache it could not use.
        if let failure = report.cacheLoadFailure {
            note("arcleak: note: \(failure)")
        }
        for issue in report.classificationIssues {
            note("arcleak: note: \(issue.message)")
            if output.verbose { for path in issue.paths { note("    \(path)") } }
        }

        // A cancelled run analysed a partial corpus and therefore reports nothing.
        // That must never read as a clean gate — exit as an internal failure,
        // with nothing on stdout.
        if report.wasCancelled {
            standardError.write(
                Data("arcleak: run cancelled before the corpus was complete; no findings reported\n".utf8))
            throw ExitCode(ExitStatus.internalFailure.rawValue)
        }

        // A corpus where EVERY file degraded analyzed nothing; exiting 0 would be
        // a green gate over unscanned code. Partial degradation stays a warning —
        // single unreadable files are reported per-file — but total failure is a
        // broken gate. The report is still printed: it names every skipped file
        // and why, and its SARIF marks the run failed. So exit 70 with a report
        // means "nothing analyzed", and exit 70 with empty stdout means the run
        // itself failed.
        if report.everyFileSkipped {
            if let relativeTo = output.relativeTo {
                report = report.relativized(to: relativeTo)
            }
            let text = ReportFormatter.format(
                report, as: OutputFormat(output.format), relativeTo: output.relativeTo, verbose: output.verbose,
                timings: output.timings)
            if !text.isEmpty {
                print(text)
            }
            standardError.write(
                Data(
                    "arcleak: every file in the corpus was skipped (unreadable, non-UTF8, or over the size cap); nothing was analyzed\n"
                        .utf8))
            throw ExitCode(ExitStatus.internalFailure.rawValue)
        }

        var promoted: Set<String> = []
        var baselineMatchesNothing = false
        if let newSinceBaseline {
            let known = Set(newSinceBaseline.fingerprints)
            baselineMatchesNothing = NewSince.matchesNothing(
                report.findings + report.outOfScope, in: known, fingerprint: \.fingerprint)
            let promotion = NewSince.promote(
                inScope: report.findings, outOfScope: report.outOfScope, notIn: known, fingerprint: \.fingerprint)
            report.findings = promotion.reported.sorted()
            report.outOfScope = promotion.outOfScope
            promoted = promotion.promoted
        }

        if let writeBaseline = output.writeBaseline {
            try outputOrExit { try Baseline(findings: report.findings).write(path: writeBaseline) }
            standardError.write(
                Data("arcleak: wrote baseline with \(report.findings.count) fingerprint(s) to \(writeBaseline)\n".utf8)
            )
        }

        var baselinedCount = 0
        if let baseline = output.baseline {
            let loaded = try baselineOrExit { try Baseline.load(path: baseline) }
            let (kept, baselined) = loaded.filter(report.findings)
            report.findings = kept
            baselinedCount = baselined.count
        }

        // SILGen confirmation shells out to xcrun, so it is macOS-only; the
        // session type does not exist elsewhere.
        #if os(macOS)
            if experimentalSilConfirm {
                let candidates = report.findings.filter { $0.rule == .storedClosureStrongSelf }
                let others = report.findings.filter { $0.rule != .storedClosureStrongSelf }
                // One session memoizes SILGen per file across all candidates.
                let session = SILConfirmationSession()
                let (kept, demoted) = await SILConfirmation.filter(findings: candidates) {
                    await session.confirmSelfCapture(file: $0.path, line: $0.line)
                }
                for finding in demoted {
                    standardError.write(
                        Data(
                            "sil-confirm: demoted \(finding.path):\(finding.line) (SILGen shows a weak capture)\n".utf8)
                    )
                }
                report.findings = (others + kept).sorted()
            }
        #else
            if experimentalSilConfirm {
                standardError.write(
                    Data("arcleak: --experimental-sil-confirm requires xcrun (macOS only)\n".utf8))
            }
        #endif

        var extraNotes: [RunNote] = []
        if let path = output.reportNewSince {
            // Counted after --baseline, so the note states what the report shows.
            let count = report.findings.count(where: { promoted.contains($0.fingerprint) })
            for message in NewSince.notes(promoted: count, matchesNothing: baselineMatchesNothing, baseline: path) {
                extraNotes.append(RunNote(code: "report-new-since", severity: "note", message: message))
                note(message)
            }
        }

        if fix || fixDryRun {
            try applyFixes(report: report)
            if fix { return }
        }

        // AFTER sil-confirm and --fix, which open finding.path for real file
        // I/O: relativized paths resolve against the CWD, so running from
        // anywhere but the root made --fix a silent no-op — or, with a
        // same-named sibling checkout, wrote fix-its into the wrong file.
        // Baselines are unaffected by the move: they match on fingerprints,
        // which are repo-anchored independently of display.
        if let relativeTo = output.relativeTo {
            report = report.relativized(to: relativeTo)
        }

        if experimental.embeddingBundle != nil, experimental.embeddings == nil {
            standardError.write(
                Data("arcleak: --embedding-bundle has no effect without --experimental-embedding-rank\n".utf8)
            )
        }

        if experimental.embeddings == .rank {
            report.findings = await rankFindings(report.findings)
        }

        let text = ReportFormatter.format(
            report, as: OutputFormat(output.format), relativeTo: output.relativeTo, runNotes: extraNotes,
            verbose: output.verbose, timings: output.timings)
        if !text.isEmpty {
            print(text)
        }
        if output.timings {
            for (phase, seconds) in report.timings.sorted(by: { $0.key < $1.key }) {
                note("arcleak: timing: \(phase) \(Int((seconds * 1000).rounded())) ms")
            }
        }
        var summary = ReportFormatter.summary(report)
        if baselinedCount > 0 {
            summary += "; \(baselinedCount) baselined"
        }
        if !report.outOfScope.isEmpty {
            summary += "; \(report.outOfScope.count) out of scope"
        }
        if report.cacheHits + report.cacheMisses > 0, !cache.noCache {
            summary += "; cache: \(report.cacheHits) reused, \(report.cacheMisses) parsed"
        }
        note(summary)

        if output.writeBaseline != nil {
            return
        }
        // Notes inform; they never fail a run, not even a strict one.
        let failed = RunOutcome.fails(report.findings.map(\.severity), strict: output.strict)
        if !failed, let stamp {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: stamp).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Not a bare `try`: ArgumentParser exits 1 on an uncaught error,
            // and 1 means findings — this gate passed.
            do {
                try Data().write(to: URL(fileURLWithPath: stamp))
            } catch {
                standardError.write(Data("arcleak: could not write the stamp \(stamp): \(error)\n".utf8))
                throw ExitCode(ExitStatus.outputFailure.rawValue)
            }
        }
        if failed {
            throw ExitCode(ExitStatus.findings.rawValue)
        }
    }

    /// Experimental: reorders findings so shape-similar ones are adjacent.
    /// Ordering only — the finding set, severities, and exit code are untouched.
    /// The note names the model that actually ran, because provider selection
    /// silently falls back (bundle → NLContextual → deterministic) and the
    /// grouping quality differs a lot between them.
    private func rankFindings(_ findings: [Finding]) async -> [Finding] {
        #if canImport(NaturalLanguage)
            guard findings.count > 1 else { return findings }
            let resolution = await EmbeddingRank.resolveProvider(bundlePath: experimental.embeddingBundle)
            if let note = resolution.note {
                standardError.write(Data("arcleak: \(note)\n".utf8))
            }
            let ranked = await EmbeddingRank.reorder(
                findings: findings,
                snippets: Self.snippets(for: findings),
                provider: resolution.provider
            )
            standardError.write(
                Data(
                    """
                    arcleak: experimental embedding-rank grouped \(ranked.count) finding(s) \
                    by flagged-site similarity [provider: \(resolution.provider.providerName)]

                    """.utf8
                )
            )
            return ranked
        #else
            standardError.write(
                Data(
                    "arcleak: experimental embedding-rank is unavailable on this platform; order unchanged\n"
                        .utf8
                )
            )
            return findings
        #endif
    }

    /// The flagged-site source line per finding (trimmed), for embedding-rank.
    /// Falls back to the rule id when the line can't be read.
    private static func snippets(for findings: [Finding]) -> [String] {
        var cache: [String: [String]] = [:]
        return findings.map { finding in
            let lines: [String]
            if let cached = cache[finding.path] {
                lines = cached
            } else {
                lines =
                    (try? String(contentsOfFile: finding.path, encoding: .utf8))?
                    .split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
                cache[finding.path] = lines
            }
            let index = finding.line - 1
            if index >= 0, index < lines.count {
                let text = String(
                    lines[index].drop(while: \.isWhitespace)
                        .reversed().drop(while: \.isWhitespace).reversed())
                if !text.isEmpty { return text }
            }
            return finding.rule.rawValue
        }
    }

    /// Resolves the opt-in index-backed type resolver, printing any fallback
    /// note. Off unless one of the `--index-store*` flags is set; never fails.
    private func resolveIndex(
        files: [String],
        configuration: Configuration
    ) async -> (any IndexReading)? {
        guard index.requested else { return nil }
        if output.verbose {
            for diagnostic in await IndexToolchainDiagnostics.resolve() {
                standardError.write(Data(("arcleak: " + diagnostic + "\n").utf8))
            }
        }
        let outcome = await IndexStoreResolution.resolve(
            projectRoot: ProjectLayout.discover(paths: input.paths)?.root ?? FileManager.default.currentDirectoryPath,
            explicitStorePath: index.indexStorePath,
            autoBuild: index.indexStoreBuild,
            analyzedFiles: files,
            defines: configuration.activeDefines,
            cacheRoot: cacheRoot()
        )
        if let note = outcome.note {
            standardError.write(Data("arcleak: \(note)\n".utf8))
        }
        return outcome.index
    }

    /// Exit codes, so CI can tell "the gate found problems" from "the gate broke".
    ///
    /// `1` means findings and nothing else: a script that posts a review comment
    /// on `1` must not also fire on a typo in the config file. `sysexits.h`
    /// supplies the rest — `64` usage (already used for bad paths), `70` an
    /// internal failure, `74` a `--fix` or `--stamp` write that failed, `78` a bad
    /// configuration or baseline. `70` prints the report when every file was
    /// skipped, and nothing when the run was cancelled, so a caller tells the
    /// two apart by whether stdout is empty.

    /// A malformed config is a broken gate, not a finding — exit 78 so CI can
    /// tell the two apart instead of reporting a typo as analysis output.

    /// A missing or corrupt baseline is a broken gate, not a finding — exit 78
    /// so CI cannot mistake it for "findings found" (exit 1).
    /// An output the run was asked to write and could not is exit 74, not a configuration error (ADR-0018).
    private func outputOrExit<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            standardError.write(Data("arcleak: \(error)\n".utf8))
            throw ExitCode(ExitStatus.outputFailure.rawValue)
        }
    }

    private func baselineOrExit<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            standardError.write(Data("arcleak: \(error)\n".utf8))
            throw ExitCode(ExitStatus.badConfiguration.rawValue)
        }
    }

    private func loadConfiguration() throws -> Configuration {
        do {
            return try loadConfigurationUncaught()
        } catch let error as ExitCode {
            throw error
        } catch {
            standardError.write(Data("arcleak: \(error)\n".utf8))
            throw ExitCode(ExitStatus.badConfiguration.rawValue)
        }
    }

    /// `--config`, or the configuration directory's shared and own files (ADR-0020).
    private func loadConfigurationUncaught() throws -> Configuration {
        let (configuration, sources) = try Configuration.resolve(
            explicit: input.config, currentDirectory: FileManager.default.currentDirectoryPath,
            analyzedPaths: input.paths)
        if output.verbose {
            for line in sources.verboseLines(tool: ToolInfo.name) { standardError.write(Data((line + "\n").utf8)) }
        }
        return configuration
    }

    /// Applies (or previews) the weak-self fix-its, grouped per file and
    /// written atomically. `--fix` exits 0 after applying — rerun to re-gate.
    private func applyFixes(report: AnalysisReport) throws {
        let fixable = report.findings.filter { FixItApplier.fixableRules.contains($0.rule) }
        let byPath = Dictionary(grouping: fixable, by: \.path).sorted { $0.key < $1.key }
        var applied = 0
        var skipped = 0
        // Transactional: compute every file's fixed source first; only commit
        // writes once all are computed, so a mid-loop failure can't leave a
        // half-fixed tree.
        var pendingWrites: [(path: String, source: String)] = []
        for (path, group) in byPath {
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let result = FixItApplier.apply(findings: group, to: source, path: path)
            applied += result.appliedCount
            skipped += result.skipped.count
            for finding in group where result.skipped.contains(finding) == false {
                standardError.write(
                    Data("\(fix ? "fixed" : "would fix"): \(path):\(finding.line) [\(finding.rule.rawValue)]\n".utf8)
                )
            }
            if fix, result.appliedCount > 0 {
                pendingWrites.append((path, result.fixedSource))
            }
        }
        if fix {
            var written: [String] = []
            for write in pendingWrites {
                do {
                    try write.source.write(toFile: write.path, atomically: true, encoding: .utf8)
                    written.append(write.path)
                } catch {
                    standardError.write(
                        Data(
                            """
                            arcleak: write failed for \(write.path): \(error)
                            arcleak: wrote \(written.count) of \(pendingWrites.count) file(s); \
                            re-run --fix after resolving the error
                            \n
                            """.utf8
                        )
                    )
                    throw ExitCode(ExitStatus.outputFailure.rawValue)
                }
            }
        }
        standardError.write(
            Data("arcleak: \(fix ? "applied" : "previewed") \(applied) fix(es); \(skipped) not auto-fixable\n".utf8)
        )
    }

    func validate() throws {
        // A baseline records the whole corpus's accepted debt. Writing one from
        // a scoped run would silently accept only the scoped subset and drop
        // everything else from the baseline, so refuse rather than surprise.
        if output.writeBaseline != nil, !input.only.isEmpty || input.onlyFrom != nil {
            throw ValidationError(
                "--write-baseline records whole-corpus debt and cannot be combined with "
                    + "--only/--only-from. Write the baseline unscoped, then scope the runs that use it."
            )
        }
        // Without a scope every finding is already reported, so there is nothing to promote (ADR-0028).
        if output.reportNewSince != nil, input.only.isEmpty, input.onlyFrom == nil {
            throw ValidationError("--report-new-since requires --only or --only-from")
        }
        if input.onlyFrom == "-", input.paths == ["-"] {
            throw ValidationError("--only-from - reads stdin, so paths cannot also come from stdin.")
        }
    }

    /// A caller-supplied path list is trust-boundary input, so the read is
    /// bounded: 2600 absolute paths is ~310 KB, and anything past the cap is a
    /// mistake or an attack rather than a change set.
    private static let scopeByteCap = 4 * 1024 * 1024

    /// nil means "report everything". An *empty* scope is meaningful and
    /// distinct: `--only-from` pointed at a change set with no Swift files, so
    /// nothing should be reported.
    private func resolveReportScope() throws -> ReportScope? {
        guard !input.only.isEmpty || input.onlyFrom != nil else { return nil }
        var entries = input.only
        if let onlyFrom = input.onlyFrom {
            entries.append(contentsOf: try readScopeEntries(from: onlyFrom))
        }
        return ReportScope(files: entries)
    }

    private func readScopeEntries(from source: String) throws -> [String] {
        let text: String
        if source == "-" {
            var accumulated = ""
            while let line = readLine(strippingNewline: true) {
                accumulated += line + "\n"
                guard accumulated.utf8.count <= Self.scopeByteCap else {
                    throw ValidationError("--only-from - exceeds the \(Self.scopeByteCap) byte cap")
                }
            }
            text = accumulated
        } else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: source)
            guard (attributes?[.type] as? FileAttributeType) == .typeRegular else {
                throw ValidationError("--only-from: not a regular file: \(source)")
            }
            if let size = attributes?[.size] as? Int, size > Self.scopeByteCap {
                throw ValidationError("--only-from: \(source) exceeds the \(Self.scopeByteCap) byte cap")
            }
            guard let contents = try? String(contentsOfFile: source, encoding: .utf8) else {
                throw ValidationError("--only-from: unreadable: \(source)")
            }
            text = contents
        }
        // Every line end, not "\n" alone: "\r\n" is one Character, so splitting on "\n" kept a CRLF file one line
        // and scoped every finding out (analyzerkit roadmap 0057). A lone CR ends a line too.
        return text.split(whereSeparator: \.isNewline)
            .map { line -> String in
                // Spaces and tabs at either end; a stray \r too, though the split
                // above already ends lines at CRLF and CR.
                let trimmable: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" }
                var entry = String(
                    line.drop(while: trimmable).reversed().drop(while: trimmable).reversed())
                // git C-quotes paths with special bytes ("So\\303\\251.swift",
                // quotes included) unless core.quotepath=false; strip the quotes
                // so at least plain-ASCII quoted paths keep matching.
                if entry.hasPrefix("\"") && entry.hasSuffix("\"") && entry.count >= 2 {
                    entry = String(entry.dropFirst().dropLast())
                        .replacing("\\\"", with: "\"").replacing("\\\\", with: "\\")
                }
                return entry
            }
            .filter { !$0.isEmpty }
    }

    /// The cache's root (`--cache-path`, or the user cache directory) and the workspace the run serves (ADR-0011);
    /// nil under `--no-cache`.
    private func cacheLocation() -> CacheLocation? {
        if cache.noCache { return nil }
        let root = cacheRoot()
        let workspace =
            ProjectLayout.discover(paths: input.paths)?.root ?? SourcePath.absolute(input.paths.first ?? ".")
        return CacheLocation(root: root, workspace: workspace)
    }

    /// `--cache-path`, or the tool's directory in the user cache directory. The index database lives under it too
    /// (analyzerkit ADR-0004), `--no-cache` or not: it is IndexStoreDB's, not the facts cache.
    private func cacheRoot() -> String {
        let environment = ProcessInfo.processInfo.environment
        return cache.cachePath.map { SourcePath.absolute($0) }
            ?? CacheLocation.defaultRoot(
                tool: ToolInfo.name, environment: environment, home: environment["HOME"] ?? "/tmp")
    }

    /// `--rules`: only the rules named run; an unknown name is a usage error.
    private func applyRules(to configuration: inout Configuration) throws {
        guard let wanted = rules.rules else { return }
        for name in wanted where RuleID(rawValue: name) == nil {
            throw ValidationError("no rule named \(name); `arcleak rules` lists them")
        }
        var settings = configuration.rules
        for rule in RuleID.allCases where !wanted.contains(rule.rawValue) {
            settings[rule.rawValue, default: Configuration.RuleSettings()].enabled = false
        }
        configuration.rules = settings
    }

    /// A line on stderr, unless `--quiet`.
    private func note(_ line: String) {
        if !output.quiet { standardError.write(Data((line + "\n").utf8)) }
    }

    private func discoverInputs(
        configuration: Configuration
    ) throws -> (swiftFiles: [String], projectFiles: [String]) {
        var files: Set<String> = []
        var projectFiles: Set<String> = []
        let fromFile = configuration.pathFilter
        let commandLine = PathFilter(input.excludePaths, root: FileManager.default.currentDirectoryPath)
        let exclusion = CombinedExclusion(fromFile: fromFile, commandLine: commandLine)
        for path in input.paths {
            guard
                // Resolved first — attributesOfItem does not traverse a final
                // symlink — and attributes rather than URL resource values,
                // which are corelibs-only.
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
                let type = attributes[.type] as? FileAttributeType
            else {
                throw ValidationError("no such file or directory: \(path)")
            }
            if type != .typeDirectory {
                if ProjectFileDiscovery.isProjectFile(path) {
                    projectFiles.insert(URL(fileURLWithPath: path).path)
                } else {
                    files.insert(URL(fileURLWithPath: path).path)
                }
                continue
            }
            files.formUnion(SourceDiscovery.swiftFiles(under: path, isExcluded: exclusion.excludes))
            projectFiles.formUnion(ProjectFileDiscovery.projectFiles(under: path, isExcluded: exclusion.excludes))
        }
        return (files.sorted(), projectFiles.sorted())
    }
}

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List every rule, or explain one: `rules <id>` prints its retention contract and fix."
    )

    @Argument(help: "Rule id to explain in full; omit to list all rules.")
    var rule: String?

    func run() throws {
        if let rule {
            guard let id = RuleID(rawValue: rule) else {
                let known = RuleID.allCases.map(\.rawValue).joined(separator: ", ")
                throw ValidationError("unknown rule \"\(rule)\" — known rules: \(known)")
            }
            print("\(id.rawValue)  [default: \(id.defaultSeverity.rawValue)]")
            print("")
            print(id.explanation)
            return
        }
        for rule in RuleID.allCases {
            print("\(rule.rawValue)  [\(rule.defaultSeverity.rawValue)]")
            print("    \(rule.summary)")
        }
        print(
            """

            Suppression:
              // @al:accept -- <why this strong reference is intentional>
              // @al:accept:this <rule|all> [-- reason]
              // @al:accept:next <rule|all> [-- reason]
              // @al:disable <rule|all> … // @al:enable <rule|all>
            """)
    }
}

/// The configuration's `exclude` and the command line's `--exclude-path`, as one filter.
struct CombinedExclusion: Sendable {
    let fromFile: PathFilter
    let commandLine: PathFilter

    func excludes(_ path: String) -> Bool { fromFile.excludes(path) || commandLine.excludes(path) }
}

extension OutputFormat {
    init(_ format: OutputOptions.Format) {
        switch format {
        case .xcode: self = .xcode
        case .json: self = .json
        case .sarif: self = .sarif
        }
    }
}
