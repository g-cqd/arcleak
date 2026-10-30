import Foundation
import SourceCorpus
import Testing

@testable import ArcLeakCore

/// The facts cache trusts only the build that wrote it, identified by its executable file (analyzerkit's
/// `CacheIdentity` folds it in).
@Suite struct BuildIdentityTests {
    @Test("The running build has an identity")
    func currentBuildIsIdentified() {
        #expect(BuildIdentity.current != nil)
    }

    @Test("Replacing an executable changes its identity; a missing one has none")
    func identityFollowsTheFile() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-build-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(BuildIdentity.identity(ofExecutableAt: path) == nil)

        try Data("first build".utf8).write(to: URL(fileURLWithPath: path))
        let first = try #require(BuildIdentity.identity(ofExecutableAt: path))
        #expect(BuildIdentity.identity(ofExecutableAt: path) == first)

        // Same size, new content: an atomic write replaces the file, as an
        // install or a relink does.
        try Data("other build".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        #expect(BuildIdentity.identity(ofExecutableAt: path) != first)
    }

}
