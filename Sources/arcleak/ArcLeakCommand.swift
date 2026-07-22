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
    var rule: String

    func run() throws {
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

    func run() async throws {
        let configuration = try loadConfiguration()
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
