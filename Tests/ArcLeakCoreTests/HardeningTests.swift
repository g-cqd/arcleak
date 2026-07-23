import ArcLeakCore
import Foundation
import Testing

/// Failure-safety regressions: each test pins one adversarial fix from the
/// performance/safety pass.
@Suite struct HardeningTests {
    // MARK: - Oversized / irregular inputs rejected without a full read

    @Test("A file over the size cap is degraded, not read into RAM")
    func oversizedFileDegraded() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = dir.appending(path: "Big.swift")
        // Sparse file: 64 MB logical, ~0 bytes on disk — the stat-first guard
        // must reject it before Data(contentsOf:) allocates 64 MB.
        let handle = try FileHandle(
            forWritingTo: {
                FileManager.default.createFile(atPath: big.path, contents: nil)
                return big
            }())
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()

        let report = await Analyzer().analyze(files: [big.path])
        #expect(report.analyzedFileCount == 1)
        #expect(report.degradedFiles.count == 1)
        #expect(report.degradedFiles.first?.detail.contains("cap") == true)
    }

    @Test("A directory path (non-regular file) is degraded, never opened for read")
    func nonRegularFileDegraded() async throws {
        // A directory is the portable non-regular target (fifo creation needs
        // the unsafe C `mkfifo`, which strict memory safety rejects in tests).
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-dir-\(UUID().uuidString).swift")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let report = await Analyzer().analyze(files: [dir.path])
        #expect(report.degradedFiles.count == 1)
        #expect(report.degradedFiles.first?.detail.contains("regular file") == true)
    }

    // MARK: - Config / baseline size guards

    @Test("Oversized configuration fails closed with a typed error")
    func oversizedConfigFailsClosed() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-cfg-\(UUID().uuidString).json").path
        // 2 MB of padded JSON — over the 1 MB config cap.
        let padding = String(repeating: "a", count: 2 * 1024 * 1024)
        try #"{"rules":{},"exclude":["\#(padding)"]}"#.write(
            toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: ArcLeakError.self) {
            try Configuration.load(path: path)
        }
    }

    // MARK: - Fix-it: co-anchored findings produce one insertion

    @Test("Two findings on one closure fix it once, output compiles clean")
    func coAnchoredClosureFixedOnce() {
        // A stored sink closure fires both stored-closure-strong-self AND
        // combine-sink-self-cycle at the same closure.
        let source = """
            import Combine
            final class Box {
                let subject = PassthroughSubject<Int, Never>()
                var cancellables = Set<AnyCancellable>()
                var handler: (() -> Void)?
                var value = 0
                func arm() {
                    handler = {
                        self.value += 1
                    }
                }
            }
            """
        let analyzer = Analyzer()
        let findings = analyzer.analyze(source: source, path: "x.swift").findings
        // Duplicate the finding to simulate two rules co-anchoring.
        let doubled = findings + findings
        let result = FixItApplier.apply(findings: doubled, to: source, path: "x.swift")
        // Exactly one `[weak self]` inserted despite two findings.
        let occurrences = result.fixedSource.components(separatedBy: "[weak self]").count - 1
        #expect(occurrences == 1)
        #expect(analyzer.analyze(source: result.fixedSource, path: "x.swift").findings.isEmpty)
    }
}
