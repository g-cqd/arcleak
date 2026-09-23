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
