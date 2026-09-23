import Foundation
import Testing

/// What a host sees when it runs the `arcleak` executable: the SARIF on
/// standard output and the exit code. GitHub code scanning and diagnostics
/// hosts consume exactly this, so it is checked on the built executable, not
/// inferred from the library.
@Suite struct CommandLineContractTests {
    private static let leakyBox = """
        final class Box {
            var handler: (() -> Void)?
            func arm() { handler = { self.fire() } }
            func fire() {}
        }
        """

    // MARK: - SARIF artifact locations

    @Test("Locations under --relative-to are relative to a base the log declares")
    func relativeLocationsDeclareTheirBase() throws {
        let root = try Workspace.make([
            "Sources/Box.swift": Self.leakyBox,
            // A cross-file cycle: the anchor in A.swift, a related location in B.swift.
            "Sources/A.swift": "final class A {\n    var b: B?\n}\n",
            "Sources/B.swift": "final class B {\n    var a: A?\n}\n",
        ])
        let run = try BuiltTool.run(
            ["analyze", root.path, "--format", "sarif", "--relative-to", root.path, "--no-cache"], in: root)
        let log = try SarifLog(run.standardOutput)

        let locations = log.artifactLocations
        #expect(Set(locations.map(\.uri)) == ["Sources/A.swift", "Sources/B.swift", "Sources/Box.swift"])
        #expect(log.relatedLocationCount > 0, "the cycle must carry a related location")
        for location in locations {
            #expect(location.uriBaseId == "SRCROOT", "\(location.uri) names no base")
        }
        let base = try #require(log.originalUriBaseIds["SRCROOT"])
        #expect(base.hasPrefix("file:///"))
        #expect(base.hasSuffix("/"), "a base uri must end with a slash (SARIF 2.1.0 §3.14.14)")
        #expect(URL(string: String(base.dropLast()))?.path == Workspace.canonical(root))
    }

    @Test("A path a relative reference cannot carry unescaped is an absolute file URI")
    func unsafePathsBecomeFileURIs() throws {
        let special = "Sources/Sub Dir/Résumé+Box#1.swift"
        let root = try Workspace.make([
            special: Self.leakyBox,
            "Sources/Plain.swift": Self.leakyBox.replacing("Box", with: "Plain"),
        ])
        let run = try BuiltTool.run(
            ["analyze", root.path, "--format", "sarif", "--relative-to", root.path, "--no-cache"], in: root)
        let locations = try SarifLog(run.standardOutput).artifactLocations

        let plain = try #require(locations.first { $0.uri == "Sources/Plain.swift" })
        #expect(plain.uriBaseId == "SRCROOT")
        let escaped = try #require(locations.first { $0.uri != "Sources/Plain.swift" })
        #expect(escaped.uri.hasPrefix("file:///"))
        #expect(escaped.uriBaseId == nil, "an absolute URI must not name a base (SARIF 2.1.0 §3.4.4)")
        #expect(Workspace.isURIReference(escaped.uri), "not a valid URI reference: \(escaped.uri)")
        #expect(URL(string: escaped.uri)?.path == Workspace.canonical(root) + "/" + special)
    }

    @Test("Without --relative-to every location is an absolute file URI")
    func absoluteLocationsAreFileURIs() throws {
        let root = try Workspace.make([
            "My Sources/Box.swift": Self.leakyBox,
            "My Sources/A.swift": "final class A {\n    var b: B?\n}\n",
            "My Sources/B.swift": "final class B {\n    var a: A?\n}\n",
        ])
        let run = try BuiltTool.run(["analyze", root.path, "--format", "sarif", "--no-cache"], in: root)
        let log = try SarifLog(run.standardOutput)

        #expect(log.originalUriBaseIds.isEmpty)
        let expected = Set(["A.swift", "B.swift", "Box.swift"].map { Workspace.canonical(root) + "/My Sources/" + $0 })
        #expect(Set(log.artifactLocations.compactMap { URL(string: $0.uri)?.path }) == expected)
        for location in log.artifactLocations {
            #expect(location.uri.hasPrefix("file:///"))
            #expect(location.uriBaseId == nil)
            #expect(Workspace.isURIReference(location.uri), "not a valid URI reference: \(location.uri)")
        }
    }

    /// One directory has several spellings: through a symlink, and on macOS
    /// with or without `/private` (`realpath(3)` keeps it, Foundation strips
    /// it). The analyzed path and `--relative-to` may each use any of them.
    @Test("Every spelling of the root gives the same locations")
    func rootSpellingsAgree() throws {
        let root = try Workspace.make([
            "Sources/Box.swift": Self.leakyBox,
            "Sources/A.swift": "final class A {\n    var b: B?\n}\n",
            "Sources/B.swift": "final class B {\n    var a: A?\n}\n",
        ])
        let link = root.deletingLastPathComponent().appending(path: root.lastPathComponent + "-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        var spellings = [root.path, link.path]
        let physical = "/private" + Workspace.canonical(root)
        if FileManager.default.fileExists(atPath: physical) { spellings.append(physical) }

        func locations(analyzing analyzed: String, relativeTo base: String) throws -> Set<String> {
            let run = try BuiltTool.run(
                ["analyze", analyzed, "--format", "sarif", "--relative-to", base, "--no-cache"], in: root)
            let log = try SarifLog(run.standardOutput)
            return Set(log.artifactLocations.map { "\($0.uriBaseId ?? "-") \($0.uri)" })
        }
        let expected = try locations(analyzing: root.path, relativeTo: root.path)
        #expect(expected == ["SRCROOT Sources/A.swift", "SRCROOT Sources/B.swift", "SRCROOT Sources/Box.swift"])
        for analyzed in spellings {
            for base in spellings {
                #expect(try locations(analyzing: analyzed, relativeTo: base) == expected, "\(analyzed) vs \(base)")
            }
        }
    }

    // MARK: - SARIF columns

    /// Text before each finding that UTF-8, UTF-16 and code points all count
    /// differently: 😀 is 4 bytes, 2 UTF-16 units and 1 code point.
    @Test("SARIF columns count UTF-16 code units, as columnKind declares")
    func columnsCountUTF16CodeUnits() throws {
        let boxLine = #"    func arm() { let _ = "😀é"; handler = { self.fire() } }"#
        let aLine = "    /* é */ var b: B?"
        let bLine = "    /* 😀 */ var a: A?"
        let root = try Workspace.make([
            "Box.swift": "final class Box {\n    var handler: (() -> Void)?\n\(boxLine)\n    func fire() {}\n}\n",
            // A cross-file cycle: the anchor in A.swift, a related location in B.swift.
            "A.swift": "final class A {\n\(aLine)\n}\n",
            "B.swift": "final class B {\n\(bLine)\n}\n",
        ])
        let run = try BuiltTool.run(
            ["analyze", root.path, "--format", "sarif", "--relative-to", root.path, "--no-cache"], in: root)
        let log = try SarifLog(run.standardOutput)

        #expect(log.columnKind == "utf16CodeUnits")
        let columns = Dictionary(grouping: log.artifactLocations, by: \.uri).mapValues { $0.compactMap(\.startColumn) }
        #expect(columns["Box.swift"] == [try Workspace.utf16Column(of: "{ self", in: boxLine)])
        #expect(columns["A.swift"] == [try Workspace.utf16Column(of: "b: B", in: aLine)])
        #expect(columns["B.swift"] == [try Workspace.utf16Column(of: "a: A", in: bLine)])
    }

    // MARK: - Facts cache

    @Test("A facts cache that cannot be used is a miss, reported at most once")
    func unusableCacheIsAMiss() throws {
        let root = try Workspace.make(["Box.swift": Self.leakyBox])
        let cache = root.appending(path: "facts.json")
        let arguments = ["analyze", root.path, "--cache-path", cache.path]

        // Valid JSON that is no cache. The released decoder read past its
        // tape on it and the process died; it is now never decoded, and a
        // file another build could have written is not worth a word.
        try Data(#""x""#.utf8).write(to: cache)
        let foreign = try BuiltTool.run(arguments, in: root)
        #expect(foreign.status == 1, "the leaky box is an error-severity finding")
        #expect(!foreign.standardError.contains("facts cache"))

        // This build's cache, cut short after its header: reported, once.
        let written = try Data(contentsOf: cache)
        let headerEnd = try #require(written.firstIndex(of: UInt8(ascii: "\n")))
        try (written[...headerEnd] + Data(#"{"entries":{"#.utf8)).write(to: cache)
        let broken = try BuiltTool.run(arguments, in: root)
        #expect(broken.status == 1)
        #expect(broken.standardError.contains("arcleak: note: ignored the facts cache"))
        let next = try BuiltTool.run(arguments, in: root)
        #expect(!next.standardError.contains("facts cache"))
        #expect(next.standardError.contains("cache: 1 reused"))
    }

    // MARK: - Exit codes

    /// Exit 70 has two causes a host must tell apart: every file was skipped,
    /// and the report on standard output says which and why; or the run failed
    /// or was cancelled, and standard output is empty.
    @Test("A run that skipped every file prints its report, then exits 70")
    func everyFileSkippedPrintsTheReport() throws {
        let root = try Workspace.make([:])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x7B]).write(to: root.appending(path: "Bad.swift"))

        let sarif = try BuiltTool.run(
            ["analyze", root.path, "--format", "sarif", "--relative-to", root.path, "--no-cache"], in: root)
        #expect(sarif.status == 70)
        #expect(sarif.standardError.contains("every file in the corpus was skipped"))
        let log = try SarifLog(sarif.standardOutput)
        #expect(log.invocation?["executionSuccessful"] as? Bool == false)
        let notifications = log.invocation?["toolExecutionNotifications"] as? [[String: Any]] ?? []
        #expect(notifications.map { $0["level"] as? String } == ["error"])
        let skipped = try #require(log.results.first)
        #expect(log.results.count == 1)
        #expect(skipped["ruleId"] as? String == "arcleak/degraded-file")
        #expect((skipped["message"] as? [String: Any])?["text"] as? String == "file skipped: not valid UTF-8")
        #expect(log.artifactLocations.map(\.uri) == ["Bad.swift"])

        let json = try BuiltTool.run(["analyze", root.path, "--format", "json", "--no-cache"], in: root)
        #expect(json.status == 70)
        let report = try #require(try JSONSerialization.jsonObject(with: json.standardOutput) as? [String: Any])
        #expect((report["degradedFiles"] as? [Any])?.count == 1)

        let xcode = try BuiltTool.run(["analyze", root.path, "--no-cache"], in: root)
        #expect(xcode.status == 70)
        #expect(String(decoding: xcode.standardOutput, as: UTF8.self).contains("file skipped: not valid UTF-8"))
    }

    /// 1 means findings and nothing else, so a gate that passed but could
    /// not leave its stamp must not exit 1.
    @Test("A stamp that cannot be written exits 74")
    func unwritableStampIsAnIOFailure() throws {
        let root = try Workspace.make(["Fine.swift": "final class Fine {}\n", "blocker": ""])
        let stamp = root.appending(path: "blocker/stamp").path  // under a regular file
        let run = try BuiltTool.run(["analyze", root.path, "--no-cache", "--stamp", stamp], in: root)
        #expect(run.status == 74)
        #expect(run.standardError.contains("stamp"))
    }

    @Test("A run that skipped some files records them and succeeds")
    func someFilesSkippedStillSucceeds() throws {
        let root = try Workspace.make(["Fine.swift": "final class Fine {}\n"])
        try Data([0xFF, 0xFE, 0x7B]).write(to: root.appending(path: "Bad.swift"))

        let run = try BuiltTool.run(
            ["analyze", root.path, "--format", "sarif", "--relative-to", root.path, "--no-cache"], in: root)
        #expect(run.status == 0)
        let log = try SarifLog(run.standardOutput)
        #expect(log.invocation?["executionSuccessful"] as? Bool == true)
        #expect(log.results.map { $0["ruleId"] as? String } == ["arcleak/degraded-file"])
    }
}

// MARK: - Harness

/// Runs the `arcleak` executable that `swift build` and `swift test` place
/// next to this test bundle.
enum BuiltTool {
    struct Run {
        let status: Int32
        let standardOutput: Data
        let standardError: String
    }

    /// SwiftPM puts every product of a build in one directory. The test
    /// resources sit in that directory on Linux and inside the `.xctest`
    /// bundle on macOS, so the executable is found among their ancestors.
    static let executable: URL? = {
        var directory = Bundle.module.bundleURL.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = directory.appending(path: "arcleak")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// Output goes to files rather than pipes, so a large report cannot fill a
    /// pipe buffer and stall the child while the test waits for it to exit.
    static func run(_ arguments: [String], in directory: URL) throws -> Run {
        let executable = try #require(
            executable, "no arcleak executable next to \(Bundle.module.bundleURL.path); build the package first")
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputURL = scratch.appending(path: "stdout")
        let errorURL = scratch.appending(path: "stderr")
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        try output.close()
        try error.close()
        return Run(
            status: process.terminationStatus,
            standardOutput: try Data(contentsOf: outputURL),
            standardError: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
    }
}

/// A scratch directory of source files.
enum Workspace {
    /// Writes each `relative path: contents` pair under a fresh directory.
    static func make(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "arcleak-cli-\(UUID().uuidString)")
        for (path, contents) in files {
            // fileURLWithPath, not appending(path:): the names under test carry
            // `#` and spaces, which must stay part of the file name.
            let url = URL(fileURLWithPath: root.path + "/" + path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// The spelling arcleak reports a path under: absolute, symlinks resolved,
    /// and on macOS without `/private`.
    static func canonical(_ url: URL) -> String {
        URL(fileURLWithPath: url.path).standardized.resolvingSymlinksInPath().path
    }

    /// The 1-based column, in UTF-16 code units, where `needle` starts in `line`.
    static func utf16Column(of needle: String, in line: String) throws -> Int {
        let range = try #require(line.range(of: needle), "\(needle) is not in \(line)")
        return line.utf16.distance(from: line.startIndex, to: range.lowerBound) + 1
    }

    /// Whether `uri` is made only of what RFC 3986 allows in a URI reference
    /// with no query or fragment: unreserved and reserved characters (less
    /// `?`, `#`, `[` and `]`) and well-formed percent escapes.
    static func isURIReference(_ uri: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/".utf8)
        let hex = Set("0123456789ABCDEFabcdef".utf8)
        let bytes = Array(uri.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, hex.contains(bytes[index + 1]), hex.contains(bytes[index + 2])
                else { return false }
                index += 3
            } else {
                guard allowed.contains(bytes[index]) else { return false }
                index += 1
            }
        }
        return true
    }
}

/// The parts of a SARIF 2.1.0 log these tests read, decoded independently of
/// the formatter that wrote it.
struct SarifLog {
    struct ArtifactLocation {
        let uri: String
        let uriBaseId: String?
        let startColumn: Int?
    }

    private let run: [String: Any]

    init(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        let log = try #require(object as? [String: Any], "standard output is not a SARIF log")
        let runs = try #require(log["runs"] as? [[String: Any]])
        run = try #require(runs.first)
    }

    var results: [[String: Any]] { run["results"] as? [[String: Any]] ?? [] }

    var columnKind: String? { run["columnKind"] as? String }

    /// The run's one invocation: whether it succeeded, and what it noted.
    var invocation: [String: Any]? { (run["invocations"] as? [[String: Any]])?.first }

    /// Every location a result points at: its own, then its related ones.
    var artifactLocations: [ArtifactLocation] {
        results.flatMap { result in
            let locations =
                (result["locations"] as? [[String: Any]] ?? [])
                + (result["relatedLocations"] as? [[String: Any]] ?? [])
            return locations.compactMap { location -> ArtifactLocation? in
                let physical = location["physicalLocation"] as? [String: Any]
                guard let artifact = physical?["artifactLocation"] as? [String: Any],
                    let uri = artifact["uri"] as? String
                else { return nil }
                let region = physical?["region"] as? [String: Any]
                return ArtifactLocation(
                    uri: uri, uriBaseId: artifact["uriBaseId"] as? String,
                    startColumn: region?["startColumn"] as? Int)
            }
        }
    }

    var relatedLocationCount: Int {
        results.reduce(0) { $0 + (($1["relatedLocations"] as? [Any])?.count ?? 0) }
    }

    /// Each declared base id and the `uri` it stands for.
    var originalUriBaseIds: [String: String] {
        let bases = run["originalUriBaseIds"] as? [String: [String: Any]] ?? [:]
        return bases.compactMapValues { $0["uri"] as? String }
    }
}
