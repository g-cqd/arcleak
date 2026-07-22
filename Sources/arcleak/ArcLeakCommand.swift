import ArcLeakCore
public import ArgumentParser
import Foundation

@main
struct ArcLeakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ToolInfo.name,
        abstract: "Static ARC analysis for Swift: retain cycles, anchor leaks, premature releases.",
        version: ToolInfo.version,
        subcommands: [Analyze.self, Rules.self, Explain.self],
        defaultSubcommand: Analyze.self
    )
}

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explain a rule: the retention contract, why it bites, and the fix."
    )

    @Argument(help: "Rule id (see `arcleak rules`).")
    var rule: String?

    @Option(name: .long, help: "Finding fingerprint (prefix ok) from a --format json report.")
    var finding: String?

    @Option(name: .long, help: "Path to the JSON report containing the finding.")
    var report: String?

    func run() throws {
        if let finding {
            guard let report else {
                throw ValidationError("--finding requires --report <analysis.json>")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: report))
            let decoded = try JSONDecoder().decode(AnalysisReport.self, from: data)
            guard
                let match = decoded.findings.first(where: { $0.fingerprint.hasPrefix(finding) })
            else {
                throw ValidationError("no finding with fingerprint prefix \"\(finding)\" in \(report)")
            }
            print("\(match.path):\(match.line):\(match.column)  [\(match.severity.rawValue)]")
            print("fingerprint: \(match.fingerprint)")
            print("")
            print(match.message)
            if let note = match.note {
                print("→ \(note)")
            }
            print("")
            print(match.rule.explanation)
            return
        }
        guard let rule else {
            throw ValidationError("provide a rule id, or --finding <fp> --report <json>")
        }
        guard let id = RuleID(rawValue: rule) else {
            let known = RuleID.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("unknown rule \"\(rule)\" — known rules: \(known)")
        }
        print("\(id.rawValue)  [default: \(id.defaultSeverity.rawValue)]")
        print("")
        print(id.explanation)
    }
}

extension OutputFormat: ExpressibleByArgument {}

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze Swift files or directories (default: current directory)."
    )

    @Argument(help: "Files or directories to analyze.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: xcode (build-log diagnostics), json, or sarif.")
    var format: OutputFormat = .xcode

    @Option(name: .long, help: "Baseline file: findings whose fingerprints appear in it are filtered out.")
    var baseline: String?

    @Option(name: .long, help: "Write the current findings as a new baseline file, then exit 0 (accept current debt).")
    var writeBaseline: String?

    @Option(name: .long, help: "Path to .arcleak.json (default: ./.arcleak.json when present).")
    var config: String?

    @Flag(name: .long, help: "Exit non-zero on any finding, not just errors.")
    var strict = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Write an empty stamp file after a successful (non-failing) run.",
            discussion:
                "Used by the build-tool plugin so the build system can skip re-analysis when inputs are unchanged."
        )
    )
    var stamp: String?

    @Option(name: .long, help: "Facts-cache file (default: ~/Library/Caches/arcleak/facts.json).")
    var cachePath: String?

    @Flag(name: .long, help: "Disable the incremental facts cache.")
    var noCache = false

    @Option(
        name: .customLong("define"),
        help: "Custom #if condition to treat as set (repeatable; the compiler's -D)."
    )
    var define: [String] = []

    @Flag(name: .long, help: "Apply mechanical [weak self] fix-its for fixable findings, in place.")
    var fix = false

    @Flag(
        name: .customLong("fix-dry-run"),
        help: "Report what --fix would change without writing files."
    )
    var fixDryRun = false

    func run() async throws {
        var configuration = try loadConfiguration()
        if !define.isEmpty {
            configuration.defines = (configuration.defines ?? []) + define
        }
        let files = try discoverSwiftFiles(configuration: configuration)
        guard !files.isEmpty else {
            throw ValidationError(ArcLeakError.noInputs.description)
        }

        var report = await Analyzer(configuration: configuration)
            .analyze(files: files, cacheURL: cacheURL())

        if let writeBaseline {
            try Baseline(findings: report.findings).write(path: writeBaseline)
            FileHandle.standardError.write(
                Data("arcleak: wrote baseline with \(report.findings.count) fingerprint(s) to \(writeBaseline)\n".utf8)
            )
        }

        var baselinedCount = 0
        if let baseline {
            let loaded = try Baseline.load(path: baseline)
            let (kept, baselined) = loaded.filter(report.findings)
            report.findings = kept
            baselinedCount = baselined.count
        }

        if fix || fixDryRun {
            try applyFixes(report: report)
            if fix { return }
        }

        let output = ReportFormatter.format(report, as: format)
        if !output.isEmpty {
            print(output)
        }
        var summary = ReportFormatter.summary(report)
        if baselinedCount > 0 {
            summary += "; \(baselinedCount) baselined"
        }
        if report.cacheHits + report.cacheMisses > 0, !noCache {
            summary += "; cache: \(report.cacheHits) reused, \(report.cacheMisses) parsed"
        }
        FileHandle.standardError.write(Data((summary + "\n").utf8))

        if writeBaseline != nil {
            return
        }
        let failed = strict ? !report.findings.isEmpty : report.maxSeverity == .error
        if !failed, let stamp {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: stamp).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: URL(fileURLWithPath: stamp))
        }
        if failed {
            throw ExitCode(1)
        }
    }

    private func loadConfiguration() throws -> Configuration {
        if let config {
            return try Configuration.load(path: config)
        }
        let implicit = FileManager.default.currentDirectoryPath + "/.arcleak.json"
        if FileManager.default.fileExists(atPath: implicit) {
            return try Configuration.load(path: implicit)
        }
        return .default
    }

    /// Applies (or previews) the weak-self fix-its, grouped per file and
    /// written atomically. `--fix` exits 0 after applying — rerun to re-gate.
    private func applyFixes(report: AnalysisReport) throws {
        let fixable = report.findings.filter { FixItApplier.fixableRules.contains($0.rule) }
        let byPath = Dictionary(grouping: fixable, by: \.path).sorted { $0.key < $1.key }
        var applied = 0
        var skipped = 0
        for (path, group) in byPath {
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let result = FixItApplier.apply(findings: group, to: source, path: path)
            applied += result.appliedCount
            skipped += result.skipped.count
            for finding in group where result.skipped.contains(finding) == false {
                FileHandle.standardError.write(
                    Data("\(fix ? "fixed" : "would fix"): \(path):\(finding.line) [\(finding.rule.rawValue)]\n".utf8)
                )
            }
            if fix, result.appliedCount > 0 {
                try result.fixedSource.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        FileHandle.standardError.write(
            Data("arcleak: \(fix ? "applied" : "previewed") \(applied) fix(es); \(skipped) not auto-fixable\n".utf8)
        )
    }

    private func cacheURL() -> URL? {
        if noCache { return nil }
        if let cachePath { return URL(fileURLWithPath: cachePath) }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches.appending(path: "arcleak/facts.json")
    }

    /// Deterministic discovery: explicit files pass through; directories are
    /// walked recursively, skipping build products and VCS internals.
    private func discoverSwiftFiles(configuration: Configuration) throws -> [String] {
        let skippedComponents: Set<String> = [".build", ".git", "DerivedData", ".swiftpm", "checkouts"]
        var files: Set<String> = []
        let manager = FileManager.default

        for path in paths {
            guard
                let isDirectory = try? URL(fileURLWithPath: path)
                    .resourceValues(forKeys: [.isDirectoryKey]).isDirectory
            else {
                throw ValidationError("no such file or directory: \(path)")
            }
            if !isDirectory {
                files.insert(path)
                continue
            }
            let root = URL(fileURLWithPath: path)
            guard
                let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for case let url as URL in enumerator {
                if skippedComponents.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else { continue }
                let filePath = url.path
                if !configuration.isExcluded(path: filePath) {
                    files.insert(filePath)
                }
            }
        }
        return files.sorted()
    }
}

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List every rule with its default severity."
    )

    func run() throws {
        for rule in RuleID.allCases {
            print("\(rule.rawValue)  [\(rule.defaultSeverity.rawValue)]")
            print("    \(rule.summary)")
        }
        print(
            """

            Suppression:
              // arcleak:deliberate -- <why this strong reference is intentional>
              // arcleak:disable:this <rule|all> [-- reason]
              // arcleak:disable:next <rule|all> [-- reason]
              // arcleak:disable <rule|all> … // arcleak:enable <rule|all>
            """)
    }
}
