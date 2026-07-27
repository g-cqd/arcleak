import ArcLeakCore
import Foundation
import Testing

/// Report scoping narrows what a run *reports*, never what it analyzes.
/// Twelve of thirteen rules are per-file and would survive a shrunken corpus,
/// but `mutual-strong-properties` walks an ownership graph spanning the whole
/// corpus — and shrinking the input also prunes the shared facts cache down to
/// the subset, cold-starting the next full run.
@Suite struct ReportScopeTests {
    private static let leaksRoot = Bundle.module.resourceURL!
        .appending(path: "Fixtures/Leaks")

    private func leakFixtures() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: Self.leaksRoot, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map(\.path)
        .sorted()
    }

    @Test("No scope reports everything and leaves outOfScope empty")
    func unscopedIsUnchanged() async throws {
        let report = await Analyzer().analyze(files: try leakFixtures())
        #expect(!report.findings.isEmpty)
        #expect(report.outOfScope.isEmpty)
    }

    @Test("Scoping to one file reports only that file, corpus intact")
    func scopeToOneFile() async throws {
        let corpus = try leakFixtures()
        let unscoped = await Analyzer().analyze(files: corpus)
        let target = try #require(unscoped.findings.first).path
        let expected = unscoped.findings.filter { $0.path == target }

        let report = await Analyzer()
            .analyze(files: corpus, reportScope: ReportScope(files: [target]))
        #expect(report.findings.map(\.fingerprint) == expected.map(\.fingerprint))
        #expect(report.outOfScope.count == unscoped.findings.count - expected.count)
        #expect(report.analyzedFileCount == unscoped.analyzedFileCount)
    }

    @Test("Scoping to the whole corpus is a no-op, fingerprints included")
    func fullScopeIsANoOp() async throws {
        let corpus = try leakFixtures()
        let unscoped = await Analyzer().analyze(files: corpus)

        let report = await Analyzer()
            .analyze(files: corpus, reportScope: ReportScope(files: corpus))
        // What lets a scoped CI run share a baseline with an unscoped one.
        #expect(report.findings.map(\.fingerprint) == unscoped.findings.map(\.fingerprint))
        #expect(report.outOfScope.isEmpty)
    }

    @Test("An empty scope reports nothing rather than everything")
    func emptyScopeIsNotAbsentScope() async throws {
        // `--only-from` pointed at a change set with no Swift files must report
        // nothing. Treating that as "no scope" would report the entire corpus
        // on exactly the pull requests that touched no code.
        let corpus = try leakFixtures()
        let report = await Analyzer()
            .analyze(files: corpus, reportScope: ReportScope(files: [] as [String]))
        #expect(report.findings.isEmpty)
        #expect(!report.outOfScope.isEmpty)
    }

    @Test("Scope entries are canonicalized, so relative paths match")
    func scopeAcceptsUncanonicalPaths() async throws {
        let corpus = try leakFixtures()
        let unscoped = await Analyzer().analyze(files: corpus)
        let target = try #require(unscoped.findings.first).path
        let awkward = URL(fileURLWithPath: target).deletingLastPathComponent()
            .appending(path: ".")
            .appending(path: URL(fileURLWithPath: target).lastPathComponent).path

        let report = await Analyzer()
            .analyze(files: corpus, reportScope: ReportScope(files: [awkward]))
        #expect(!report.findings.isEmpty)
        #expect(report.findings.allSatisfy { $0.path == target })
    }

    @Test("A cross-file cycle survives scoping to the file it anchors at")
    func corpusRuleSurvivesScoping() async throws {
        // `mutual-strong-properties` only exists because the graph spans the
        // corpus. Scoping must not disturb it — and the documented narrowing
        // is that it matches on its anchor file, since the other participants
        // live in the note as free text rather than as structured locations.
        let corpusRoot = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        ).appending(path: "Corpus/MutualPair")
        let files = try FileManager.default
            .contentsOfDirectory(at: corpusRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map(\.path)
            .sorted()

        let unscoped = await Analyzer().analyze(files: files)
        let cycle = try #require(unscoped.findings.first { $0.rule == .mutualStrongProperties })

        let scoped = await Analyzer()
            .analyze(files: files, reportScope: ReportScope(files: [cycle.path]))
        #expect(scoped.findings.map(\.fingerprint) == [cycle.fingerprint])
    }
}
