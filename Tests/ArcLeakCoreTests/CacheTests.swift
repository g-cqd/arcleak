import ArcLeakCore
import Foundation
import Testing

@Suite struct CacheTests {
    private func makeWorkspace() throws -> (dir: URL, cache: URL, files: [String]) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        let cache = dir.appending(path: "facts-cache.json")
        return (dir, cache, [first.path, second.path])
    }

    @Test func warmRunReusesFactsAndFindingsMatch() async throws {
        let (_, cache, files) = try makeWorkspace()

        let cold = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(cold.cacheHits == 0)
        #expect(cold.cacheMisses == 2)
        #expect(cold.findings.count == 1)

        let warm = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(warm.cacheHits == 2)
        #expect(warm.cacheMisses == 0)
        #expect(warm.findings == cold.findings)
    }

    @Test func editedFileInvalidatesOnlyItsEntry() async throws {
        let (dir, cache, files) = try makeWorkspace()
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        let edited = dir.appending(path: "Fine.swift")
        try """
        final class Fine {
            var onTick: (() -> Void)?
            func arm() { onTick = { self.tick() } }
            func tick() {}
        }
        """.write(to: edited, atomically: true, encoding: .utf8)

        let rerun = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(rerun.cacheHits == 1)
        #expect(rerun.cacheMisses == 1)
        #expect(rerun.findings.count == 2)
    }

    @Test func prunesEntriesForFilesAbsentThisRun() async throws {
        let (dir, cache, files) = try makeWorkspace()
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        // Re-run on only the first file — the cache must no longer carry the
        // second file's entry (per-run rebuild, not append-forever).
        let subset = [files[0]]
        _ = await Analyzer().analyze(files: subset, cacheURL: cache)
        let reloaded = FactsCache.load(url: cache)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.keys.contains(files[0]))
        _ = dir
    }

    @Test func cancelledAnalysisReturnsEarly() async throws {
        let (_, cache, files) = try makeWorkspace()
        let task = Task { await Analyzer().analyze(files: files, cacheURL: cache) }
        task.cancel()
        let report = await task.value
        // No crash, a well-formed (possibly partial) report.
        #expect(report.analyzedFileCount == files.count)
    }

    @Test func corruptCacheFailsOpen() async throws {
        let (_, cache, files) = try makeWorkspace()
        try "not json at all {{{".write(to: cache, atomically: true, encoding: .utf8)

        let report = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(report.cacheHits == 0)
        #expect(report.cacheMisses == 2)
        #expect(report.findings.count == 1)

        // And the bad file was overwritten with a valid cache.
        let warm = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(warm.cacheHits == 2)
    }

    @Test func toolVersionMismatchDiscardsCache() throws {
        var cache = FactsCache()
        cache.update(
            path: "/tmp/x.swift",
            fingerprint: "abc",
            facts: FileFacts(path: "/tmp/x.swift")
        )
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-version-test-\(UUID().uuidString).json")
        cache.persist(url: url)

        var onDisk = try #require(
            String(data: Data(contentsOf: url), encoding: .utf8)
        )
        onDisk = onDisk.replacingOccurrences(of: ToolInfo.version, with: "0.0.0-other")
        try onDisk.write(to: url, atomically: true, encoding: .utf8)

        let reloaded = FactsCache.load(url: url)
        #expect(reloaded.entries.isEmpty)
    }

    /// A `FileFacts` exercising every fact type and enum shape the ADJSON coder
    /// touches — including the associated-value enums that ride the generic
    /// Codable bridge (`APICallFact.Kind`, `SelfCaptureKind`, `ResultConsumption`)
    /// and the ones a live corpus rarely produces (`APICallFact`).
    private func richFacts(path: String) -> FileFacts {
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

    @Test func realisticPayloadRoundTripsByteStableAndLossless() throws {
        var cache = FactsCache()
        cache.update(path: "/x/Sample.swift", fingerprint: "fp-1", facts: richFacts(path: "/x/Sample.swift"))
        cache.update(path: "/x/Another.swift", fingerprint: "fp-2", facts: FileFacts(path: "/x/Another.swift"))

        let url = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-rt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Byte-stable AND lossless: persist -> load -> re-persist is
        // byte-identical. Sets encode sorted, so this holds regardless of how the
        // sets were built (freshly constructed here vs decoder-rebuilt on load);
        // if the round-trip dropped or mangled ANY field the re-persist would
        // diverge from the first.
        cache.persist(url: url)
        let first = try Data(contentsOf: url)
        let loaded = FactsCache.load(url: url)
        #expect(loaded.entries.count == 2)
        loaded.persist(url: url)
        let second = try Data(contentsOf: url)
        #expect(first == second)

        // Spot-check the associated-value enums that ride ADJSON's generic Codable
        // bridge (a live corpus rarely produces APICallFact) — they must survive
        // verbatim through the round-trip.
        let type = try #require(loaded.entries["/x/Sample.swift"]?.facts.types.first)
        #expect(type.apiCalls.count == 3)
        #expect(type.apiCalls[1].kind == .userTokenProducer("React.to"))
        #expect(type.apiCalls[0].consumption == .storedToSelfMember("bag"))
        #expect(type.apiCalls[0].closureSelfCapture == .strong(implicit: true))
        #expect(type.apiCalls[2].closureSelfCapture == SelfCaptureKind.none)
        #expect(type.taskSpawns.first?.consumption == .storedToLocalOnly("t"))
        #expect(type.storedClosures.first?.selfCapture == .strong(implicit: false))
    }

    @Test func allHitsWarmRunSkipsRepersist() async throws {
        let (dir, cache, files) = try makeWorkspace()

        // Cold run writes the cache.
        let cold = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(cold.cacheMisses == 2)

        // Stamp a known past mtime; an atomic re-persist would replace the file
        // and reset it to "now".
        let past = Date(timeIntervalSince1970: 946_684_800)  // 2000-01-01
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: cache.path)

        // All hits, nothing to prune -> the guard skips the redundant re-persist.
        let warm = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(warm.cacheHits == 2)
        #expect(warm.cacheMisses == 0)
        let untouched =
            try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date
        #expect(untouched?.timeIntervalSince1970 == past.timeIntervalSince1970)

        // A miss must still persist (the cache is rebuilt): edit one file so the
        // next run has a miss, and confirm the file was rewritten.
        try """
        final class Fine { var onTick: (() -> Void)?; func arm() { onTick = { self.t() } }; func t() {} }
        """.write(to: dir.appending(path: "Fine.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: cache.path)
        let rerun = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(rerun.cacheMisses == 1)
        let rewritten =
            try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date
        #expect((rewritten?.timeIntervalSince1970 ?? 0) > past.timeIntervalSince1970)
    }
}
