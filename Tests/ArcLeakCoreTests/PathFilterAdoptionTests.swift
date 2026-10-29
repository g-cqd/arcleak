import ArcLeakCore
import Foundation
import Testing

/// `exclude` follows ADR-0008, the rule every tool shares: substrings as before, globs relative to the configuration
/// file's directory (analyzerkit roadmap 0005).
@Suite struct PathFilterAdoptionTests {
    private static let entries = ["Sources/*/Internal", "/*.swift", "Generated/"]

    private func withProject(_ body: (_ root: String, _ config: Configuration) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "arcleak-exclude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: ".arcleak.json")
        try JSONSerialization.data(withJSONObject: ["exclude": Self.entries]).write(to: file)
        try await body(root.path, try Configuration.load(path: file.path))
    }

    @Test func `globs are relative to the configuration file and substrings keep their meaning`() async throws {
        try await withProject { root, config in
            #expect(config.isExcluded(path: root + "/Sources/App/Internal/Secret.swift"))
            #expect(config.isExcluded(path: root + "/Package.swift"))
            #expect(config.isExcluded(path: root + "/Sources/Generated/API.swift"))
            #expect(!config.isExcluded(path: root + "/Sources/App/Internal.swift"))
            #expect(!config.isExcluded(path: root + "/Sources/App/App.swift"))
        }
    }

    @Test func `the analyzer leaves out the files a glob excludes`() async throws {
        try await withProject { root, config in
            var paths: [String] = []
            for name in ["Sources/App/Internal/Secret.swift", "Package.swift", "Sources/App/App.swift"] {
                let url = URL(fileURLWithPath: root + "/" + name)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "struct S {}\n".write(to: url, atomically: true, encoding: .utf8)
                paths.append(url.path)
            }
            let report = await Analyzer(configuration: config).analyze(files: paths)
            #expect(report.analyzedFileCount == 1)
        }
    }
}
