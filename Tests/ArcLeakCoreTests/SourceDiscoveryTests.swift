import ArcLeakCore
import Foundation
import Testing

/// The directory walk follows symlinked directories — a linked `Sources/` is a
/// real layout — so it must also survive links that reach a directory twice
/// or point back up the tree.
@Suite struct SourceDiscoveryTests {
    /// `Sources/Sub/Loop` points back at the root, and `Alias` is a second way
    /// into `Sources/Leaf`, unless `linked` is false.
    private func makeTree(linked: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "arcleak-walk-\(UUID().uuidString)")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: root) } }
        let sources = root.appending(path: "Sources")
        for directory in ["Sub", "Leaf"] {
            try FileManager.default.createDirectory(
                at: sources.appending(path: directory), withIntermediateDirectories: true)
        }
        for (path, name) in [("A.swift", "A"), ("Sub/B.swift", "B"), ("Leaf/C.swift", "C")] {
            try "final class \(name) {}\n".write(
                to: sources.appending(path: path), atomically: true, encoding: .utf8)
        }
        guard linked else {
            completed = true
            return root
        }
        try FileManager.default.createSymbolicLink(
            atPath: sources.appending(path: "Sub/Loop").path, withDestinationPath: "../..")
        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "Alias").path, withDestinationPath: "Sources/Leaf")
        completed = true
        return root
    }

    @Test("Each directory is walked once, however many links reach it")
    func linkedDirectoriesAreWalkedOnce() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SourceDiscovery.swiftFiles(under: root.path) { _ in false }

        // One spelling per file: a link back up the tree used to re-walk it
        // under every longer spelling until the kernel gave up (ELOOP), and
        // two such links never finished.
        #expect(files.count == 3, "\(files.count) spellings: \(files.prefix(6))")
        let canonicalRoot = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path
        let resolved = Set(files.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        #expect(resolved == Set(["A", "Sub/B", "Leaf/C"].map { canonicalRoot + "/Sources/\($0).swift" }))
    }

    /// Exclusion matches the spelling a file is reached by. A link named like
    /// an exclude pattern — `Vendor`, pointing at `Sources/Sub` — must not
    /// claim the directory behind it, or that directory's files vanish with
    /// the link's. A directory from outside the tree, linked in and excluded
    /// by its name in the tree, stays out.
    @Test("An excluded link does not hide the directory it points to")
    func excludedLinkDoesNotHideItsTarget() throws {
        let root = try makeTree(linked: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "Vendor").path, withDestinationPath: "Sources/Sub")
        let outside = FileManager.default.temporaryDirectory.appending(path: "arcleak-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "final class D {}\n".write(to: outside.appending(path: "D.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "External").path, withDestinationPath: outside.path)

        let files = SourceDiscovery.swiftFiles(under: root.path) {
            $0.contains("/Vendor/") || $0.contains("/External/")
        }
        #expect(files.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted() == ["A.swift", "B.swift", "C.swift"])
    }

    @Test("Hidden entries, build products and excluded files are skipped")
    func skipsWhatItShould() throws {
        let root = try makeTree(linked: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for hidden in [".hidden/H.swift", ".build/debug/D.swift", "DerivedData/E.swift"] {
            let url = root.appending(path: hidden)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "final class H {}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let files = SourceDiscovery.swiftFiles(under: root.path) { $0.hasSuffix("/C.swift") }
        #expect(files.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted() == ["A.swift", "B.swift"])
    }
}
