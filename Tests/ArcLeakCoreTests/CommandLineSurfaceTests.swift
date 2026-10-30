import Foundation
import Testing

/// arcleak's `analyze` on analyzerkit's shared option groups (ADR-0019, roadmap 0018): Input, Output, Rules, Cache,
/// Index and Experimental, with the old spellings kept as aliases, and regions from the project.
@Suite(.serialized) struct CommandLineSurfaceTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// A stored closure capturing `self` strongly: one error-severity cycle.
    private static func box(_ name: String) -> String {
        "final class \(name) {\n    var handler: (() -> Void)?\n    func arm() { handler = { self.fire() } }\n"
            + "    func fire() {}\n}\n"
    }

    struct Run {
        let status: Int32
        let output: String
        let errors: String
    }

    private static func executable() throws -> URL {
        let build = packageRoot.appending(path: ".build")
        let candidates = ["debug", "release"].map { build.appending(path: "\($0)/arcleak") }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        func modified(_ url: URL) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate]
                as? Date ?? .distantPast
        }
        return try #require(candidates.max { modified($0) < modified($1) }, "build arcleak first")
    }

    private static func run(_ arguments: [String], in root: URL) throws -> Run {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus, output: String(decoding: out, as: UTF8.self),
            errors: String(decoding: err, as: UTF8.self))
    }

    private static func workspace(_ files: [String: String], _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "arcleak-cli-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("gitdir: none\n".utf8).write(to: root.appending(path: ".git"))
        for (name, text) in files {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try body(root)
    }

    @Test func `the help lists every shared option and arcleak's own after them`() throws {
        try Self.workspace([:]) { root in
            let run = try Self.run(["analyze", "--help"], in: root)
            for option in [
                "--config", "--exclude-path", "--include-regions", "--exclude-regions", "--define", "--only",
                "--only-from", "--format", "--relative-to", "--strict", "--baseline", "--write-baseline",
                "--report-new-since", "--verbose", "--quiet", "--timings", "--rules", "--cache-path", "--no-cache",
                "--index-store", "--index-store-path", "--index-store-build", "--experimental-embeddings",
                "--embedding-bundle", "--fix", "--fix-dry-run", "--experimental-sil-confirm",
            ] {
                #expect(run.output.contains(option), "missing \(option)")
            }
        }
    }

    @Test func `the old region and embedding spellings still work, with a note`() throws {
        try Self.workspace(["Box.swift": Self.box("Box")]) { root in
            let run = try Self.run(["analyze", ".", "--no-cache", "--include", "test", "--exclude", "mock"], in: root)
            #expect(run.errors.contains("arcleak: note: --include is deprecated; use --include-regions"))
            #expect(run.errors.contains("arcleak: note: --exclude is deprecated; use --exclude-regions"))
            #expect(run.status == 1)
        }
    }

    @Test func `exclude-path leaves a file out`() throws {
        try Self.workspace(["A.swift": Self.box("A"), "B.swift": Self.box("B")]) { root in
            let run = try Self.run(["analyze", ".", "--no-cache", "--exclude-path", "B.swift"], in: root)
            #expect(run.output.contains("A.swift") && !run.output.contains("B.swift"))
        }
    }

    @Test func `rules chooses the rules that run, and an unknown one is a usage error`() throws {
        try Self.workspace(["Box.swift": Self.box("Box")]) { root in
            let other = try Self.run(["analyze", ".", "--no-cache", "--rules", "timer-retains-self"], in: root)
            #expect(other.status == 0 && other.output.isEmpty)
            let same = try Self.run(["analyze", ".", "--no-cache", "--rules", "stored-closure-strong-self"], in: root)
            #expect(same.output.contains("stored-closure-strong-self"))
            let unknown = try Self.run(["analyze", ".", "--no-cache", "--rules", "nope"], in: root)
            #expect(unknown.status == 64)
        }
    }

    @Test func `quiet, verbose and timings`() throws {
        try Self.workspace(["Box.swift": Self.box("Box")]) { root in
            let quiet = try Self.run(["analyze", ".", "--no-cache", "--quiet"], in: root)
            #expect(quiet.errors.isEmpty)
            let verbose = try Self.run(["analyze", ".", "--no-cache", "--verbose"], in: root)
            #expect(verbose.errors.contains("arcleak: configuration: no file found; built-in defaults"))
            let timed = try Self.run(["analyze", ".", "--no-cache", "--format", "json", "--timings"], in: root)
            #expect(timed.output.contains("\"timings\""))
        }
    }

    /// `--timings` reports the time of each phase: in the JSON report and on stderr, not an empty object.
    @Test func `timings name the scan and the rules`() throws {
        try Self.workspace(["Box.swift": Self.box("Box")]) { root in
            let timed = try Self.run(["analyze", ".", "--no-cache", "--format", "json", "--timings"], in: root)
            let object = try JSONSerialization.jsonObject(with: Data(timed.output.utf8)) as? [String: Any]
            let timings = object?["timings"] as? [String: Double] ?? [:]
            #expect(Set(timings.keys) == ["scan", "rules"], "\(timings)")
            #expect(timed.errors.contains("arcleak: timing: scan"), "\(timed.errors)")
        }
    }

    /// The base branch's baseline holds A's cycle; the change adds B's and touches only C.
    @Test func `report-new-since reports out-of-scope findings the base baseline lacks`() throws {
        try Self.workspace(["A.swift": Self.box("A"), "C.swift": "let c = 1\n"]) { root in
            let base = try Self.run(["analyze", ".", "--no-cache", "--write-baseline", "base.json"], in: root)
            #expect(base.status == 0)
            try Data(Self.box("B").utf8).write(to: root.appending(path: "B.swift"))
            let run = try Self.run(
                ["analyze", ".", "--no-cache", "--only", "C.swift", "--report-new-since", "base.json"], in: root)
            #expect(run.output.contains("B.swift") && !run.output.contains("A.swift"))
            #expect(run.errors.contains("1 finding(s) outside --only are new since base.json"))
            let unscoped = try Self.run(["analyze", ".", "--no-cache", "--report-new-since", "base.json"], in: root)
            #expect(unscoped.status == 64)
        }
    }

    /// `--cache-path` names the cache's root directory (ADR-0011); a second run reuses every file.
    @Test func `a cache under cache-path is a directory and is reused`() throws {
        try Self.workspace(["A.swift": Self.box("A"), "B.swift": "let b = 1\n"]) { root in
            let cache = root.appending(path: "cache").path
            _ = try Self.run(["analyze", ".", "--cache-path", cache], in: root)
            let type = (try? FileManager.default.attributesOfItem(atPath: cache))?[.type] as? FileAttributeType
            #expect(type == .typeDirectory)
            let warm = try Self.run(["analyze", ".", "--cache-path", cache, "--format", "json"], in: root)
            #expect(warm.output.contains(#""cacheHits" : 2"#))
        }
    }

    /// A cycle in a test target the manifest declares outside `Tests/` carries the test-code note.
    @Test func `a test target outside Tests is test code`() throws {
        let manifest = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "P", targets: [
                .target(name: "Lib", path: "Lib"), .testTarget(name: "Checks", dependencies: ["Lib"], path: "Checks"),
            ])
            """
        try Self.workspace(["Package.swift": manifest, "Checks/C.swift": Self.box("C"), "Lib/L.swift": "let l = 1\n"]) {
            root in
            let run = try Self.run(["analyze", ".", "--no-cache"], in: root)
            #expect(run.output.contains("test code: the object lives for the test run at most"), "\(run.output)")
        }
    }
}
