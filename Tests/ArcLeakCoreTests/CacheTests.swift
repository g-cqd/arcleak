//  The facts cache is an optimization and must never change results: hit and miss runs give identical findings.
//  The cache itself (shards, corruption failing open, the build identity, pruning, the budget) is analyzerkit's
//  CorpusScanner, tested there (roadmap 0018); what stays here is what arcleak keys and stores.

import AemiJSON
import ArcLeakCore
import CorpusScan
import Foundation
import Testing

@Suite struct CacheTests {
    private func makeWorkspace() throws -> (dir: URL, cache: CacheLocation, files: [String]) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let leaky = """
                final class Box {
                    var handler: (() -> Void)?
                    func arm() { handler = { self.fire() } }
                    func fire() {}
                }
                """
            let clean = """
                final class Fine {
                    var value = 0
                    func bump() { value += 1 }
                }
                """
            let first = dir.appending(path: "Leaky.swift")
            let second = dir.appending(path: "Fine.swift")
            try leaky.write(to: first, atomically: true, encoding: .utf8)
            try clean.write(to: second, atomically: true, encoding: .utf8)
            let cache = CacheLocation(root: dir.appending(path: "cache").path, workspace: dir.path)
            return (dir, cache, [first.path, second.path])
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    @Test func warmRunReusesFactsAndFindingsMatch() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cold = await Analyzer().analyze(files: files, cache: cache)
        #expect(cold.cacheHits == 0)
        #expect(cold.cacheMisses == 2)
        #expect(cold.findings.count == 1)

        let warm = await Analyzer().analyze(files: files, cache: cache)
        #expect(warm.cacheHits == 2)
        #expect(warm.cacheMisses == 0)
        #expect(warm.findings == cold.findings)
    }

    @Test func editedFileInvalidatesOnlyItsEntry() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cache: cache)

        let edited = dir.appending(path: "Fine.swift")
        try """
        final class Fine {
            var onTick: (() -> Void)?
            func arm() { onTick = { self.tick() } }
            func tick() {}
        }
        """.write(to: edited, atomically: true, encoding: .utf8)

        let rerun = await Analyzer().analyze(files: files, cache: cache)
        #expect(rerun.cacheHits == 1)
        #expect(rerun.cacheMisses == 1)
        #expect(rerun.findings.count == 2)
    }

    /// The cache is shared by every run in a workspace, and a run over part of the corpus (a pull request's files,
    /// one file from an editor) must not evict the rest: the next whole-corpus run would start cold.
    @Test func subsetRunKeepsEntriesOfFilesItDidNotAnalyze() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cache: cache)
        _ = await Analyzer().analyze(files: [files[0]], cache: cache)

        let whole = await Analyzer().analyze(files: files, cache: cache)
        #expect(whole.cacheHits == 2)
    }

    /// Facts depend on the `#if` configuration: other defines must not reuse them.
    @Test func otherDefinesMissTheCache() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cache: cache)

        let defined = await Analyzer(configuration: Configuration(defines: ["EXTRA"])).analyze(
            files: files, cache: cache)
        #expect(defined.cacheHits == 0)
        #expect(defined.cacheMisses == 2)
    }

    /// A file that could not be analysed is cached as such, and reported the same on a warm run.
    @Test func unanalysableFileIsReportedFromTheCacheToo() async throws {
        let (dir, cache, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unreadable = dir.appending(path: "Bad.swift")
        try Data([0xFF, 0xFE, 0x7B]).write(to: unreadable)

        let cold = await Analyzer().analyze(files: [unreadable.path], cache: cache)
        let warm = await Analyzer().analyze(files: [unreadable.path], cache: cache)
        #expect(cold.degradedFiles.map(\.detail) == ["not valid UTF-8"])
        #expect(warm.degradedFiles.map(\.detail) == ["not valid UTF-8"])
    }

    /// A cancelled run must report *nothing*, not a partial answer: `mutual-strong-properties` walks an ownership
    /// graph built from the whole corpus, so a partial run draws conclusions from a corpus that is missing files.
    /// A cancelled run is a failed run, and the CLI exits 70 for it.
    @Test func cancelledAnalysisReportsNothing() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = Task { await Analyzer().analyze(files: files, cache: cache) }
        task.cancel()
        let report = await task.value
        #expect(report.wasCancelled)
        #expect(report.findings.isEmpty)
        #expect(report.outOfScope.isEmpty)
    }

    /// A `FileFacts` exercising every fact type and enum shape the AemiJSON coder
    /// touches — including the associated-value enums that ride the generic
    /// Codable bridge (`APICallFact.Kind`, `SelfCaptureKind`, `ResultConsumption`)
    /// and the ones a live corpus rarely produces (`APICallFact`).
    static func richFacts(path: String) -> FileFacts {
        var type = TypeFacts(name: "Model", isReferenceType: true)
        type.memberNames = ["a", "b", "handler"]
        type.inheritedTypeNames = ["NSObject", "ObservableObject"]
        type.methodNames = ["run", "stop"]
        type.attributeNames = ["Observable"]
        type.deadWeakCaptures = [SourcePosition(line: 5, column: 9)]
        type.storedProperties = [
            StoredPropertyFact(
                name: "child", strength: .strong, referencedTypeNames: ["Child"],
                position: SourcePosition(line: 2, column: 5)),
            StoredPropertyFact(
                name: "parent", strength: .weak, referencedTypeNames: ["Parent"],
                hasPublishedAttribute: true, position: SourcePosition(line: 3, column: 5)),
            StoredPropertyFact(
                name: "owner", strength: .unowned, referencedTypeNames: [],
                hasTransientAttribute: true, position: SourcePosition(line: 4, column: 5)),
        ]
        type.storedClosures = [
            StoredClosureFact(
                position: SourcePosition(line: 6, column: 5), targetMember: "handler",
                selfCapture: .strong(implicit: false)),
            StoredClosureFact(
                position: SourcePosition(line: 7, column: 5), targetMember: "onTick",
                selfCapture: .weak, isMethodReference: true),
        ]
        type.apiCalls = [
            APICallFact(
                kind: .combineSink, position: SourcePosition(line: 8, column: 5), repeats: nil,
                targetIsSelf: true, upstreamFiniteness: .infinite, upstreamRootMember: "subject",
                closureSelfCapture: .strong(implicit: true), consumption: .storedToSelfMember("bag")),
            APICallFact(
                kind: .userTokenProducer("React.to"), position: SourcePosition(line: 9, column: 5),
                repeats: true, targetIsSelf: false, receiverIsSelfMember: true,
                closureSelfCapture: nil, selfCaptureViaNestedListOnly: true,
                consumption: .chainedStoreIn(memberOfSelf: true)),
            APICallFact(
                kind: .timerScheduledTarget, position: SourcePosition(line: 11, column: 5),
                repeats: false, targetIsSelf: true, closureSelfCapture: SelfCaptureKind.none,
                consumption: .discarded),
        ]
        type.taskSpawns = [
            TaskSpawnFact(
                position: SourcePosition(line: 12, column: 5), selfCapture: .unowned,
                hasNonterminatingBody: true, consumption: .storedToLocalOnly("t"))
        ]
        type.releaseSites = [
            ReleaseSite(kind: .invalidate, inDeinit: false),
            ReleaseSite(kind: .sessionInvalidate, inDeinit: true),
        ]
        return FileFacts(
            path: path,
            types: [type, TypeFacts(name: "Empty", isReferenceType: nil)],
            directives: [
                SuppressionDirective(
                    rules: [.timerRetainsSelf, .combineSinkSelfCycle], kind: .accept, line: 3,
                    reason: "intentional"),
                SuppressionDirective(rules: [], kind: .regionDisable, line: 10, reason: nil),
            ])
    }

    /// What the cache stores goes through AemiJSON, as `CorpusScanner` writes and reads it: byte-stable and lossless.
    @Test func realisticPayloadRoundTripsByteStableAndLossless() throws {
        let stored = ExtractedFacts(facts: Self.richFacts(path: "/x/Sample.swift"))
        let first = try AemiJSON.JSONEncoder().encodeToBytes(stored)
        let loaded = try AemiJSON.JSONDecoder().decode(ExtractedFacts.self, from: first)
        #expect(try AemiJSON.JSONEncoder().encodeToBytes(loaded) == first)

        // The associated-value enums ride AemiJSON's generic Codable bridge and must survive verbatim.
        let type = try #require(loaded.facts?.types.first)
        #expect(type.apiCalls.count == 3)
        #expect(type.apiCalls[1].kind == .userTokenProducer("React.to"))
        #expect(type.apiCalls[0].consumption == .storedToSelfMember("bag"))
        #expect(type.apiCalls[0].closureSelfCapture == .strong(implicit: true))
        #expect(type.apiCalls[2].closureSelfCapture == SelfCaptureKind.none)
        #expect(type.taskSpawns.first?.consumption == .storedToLocalOnly("t"))
        #expect(type.storedClosures.first?.selfCapture == .strong(implicit: false))
    }
}
