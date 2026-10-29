import ArcLeakCore
import Foundation
import Testing

/// A deeply nested file never crashes the run: one nested within reason is analysed on the large stack, one nested past
/// the limit is listed as degraded, and the rest of the corpus is analysed as usual (analyzerkit roadmap 0041).
@Suite struct DeepTreeTests {
    private static func chain(_ links: Int) -> String {
        "func f() {\n    let v = view" + String(repeating: ".m(1)", count: links) + "\n    print(v)\n}\n"
    }

    @Test func `a deep file is analysed or listed as degraded, and the corpus still reports`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "arcleak-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cycle =
            "class Hub {\n    var handler: (() -> Void)?\n    func fire() {}\n    func arm() {\n"
            + "        handler = { self.fire() }\n    }\n}\n"
        var paths: [String] = []
        for (name, text) in [("Deep", Self.chain(3_000)), ("Deeper", Self.chain(15_000)), ("Hub", cycle)] {
            let url = root.appending(path: "\(name).swift")
            try text.write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.path)
        }
        let report = await Analyzer().analyze(files: paths)
        #expect(report.findings.map(\.rule) == [.storedClosureStrongSelf], "the ordinary file is still analysed")
        #expect(report.degradedFiles.map { ($0.path as NSString).lastPathComponent } == ["Deeper.swift"])
        #expect(report.degradedFiles.first?.detail.contains("nested") == true)
    }
}
