import Foundation
import Testing

@testable import ArcLeakCore

/// The facts cache trusts only the build that wrote it, identified by its
/// executable file.
@Suite struct BuildIdentityTests {
    @Test("The running build has an identity")
    func currentBuildIsIdentified() {
        #expect(BuildIdentity.current != nil)
    }

    @Test("Replacing an executable changes its identity; a missing one has none")
    func identityFollowsTheFile() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-build-\(UUID().uuidString)").path
        #expect(BuildIdentity.identity(ofExecutableAt: path) == nil)

        try Data("first build".utf8).write(to: URL(fileURLWithPath: path))
        let first = try #require(BuildIdentity.identity(ofExecutableAt: path))
        #expect(BuildIdentity.identity(ofExecutableAt: path) == first)

        // Same size, new content: an atomic write replaces the file, as an
        // install or a relink does.
        try Data("other build".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        #expect(BuildIdentity.identity(ofExecutableAt: path) != first)
    }

    @Test("A cache is read back only by the build that wrote it")
    func cacheIsScopedToItsBuild() {
        var cache = FactsCache()
        cache.update(path: "/x/A.swift", fingerprint: "fp", facts: FileFacts(path: "/x/A.swift"))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-build-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        cache.persist(url: url, build: "build-a")
        #expect(FactsCache.load(url: url, build: "build-a").entries.count == 1)
        #expect(FactsCache.load(url: url, build: "build-b").entries.isEmpty)
        #expect(FactsCache.load(url: url, build: nil).entries.isEmpty)

        cache.persist(url: url, build: nil)
        #expect(FactsCache.load(url: url, build: "build-a").entries.count == 1, "no identity writes nothing")
    }
}
