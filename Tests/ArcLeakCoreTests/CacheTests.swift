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
}
