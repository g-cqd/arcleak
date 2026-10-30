#if os(macOS)
    @testable import ArcLeakCore
    import Foundation
    import Testing

    /// The IndexStoreDB-backed resolver, end to end. A fresh two-file index is built with the `swiftc` that matches the
    /// `libIndexStore.dylib` the resolver loads; arcleak then analyzes only one of the two mutually referencing files:
    /// with the index it reports the cross-module cycle (the counterpart is found and parsed through the index), without
    /// it stays silent.
    ///
    /// Enabled only where such a store can be built (A9 of analyzerkit's index probes: the test used to return early, and
    /// pass, whenever any step failed). Where it runs, every step must succeed.
    @Suite(.enabled(if: IndexFixture.available, "needs a swiftc matching libIndexStore.dylib"))
    struct IndexStoreBackendTests {
        @Test("A prebuilt index unlocks a cross-module cycle the default mode misses")
        func indexUnlocksCrossModuleCycle() async throws {
            let dir = try IndexFixture.directory()
            defer { try? FileManager.default.removeItem(at: dir) }

            let hub = dir.appending(path: "Hub.swift")
            let plugin = dir.appending(path: "Plugin.swift")
            try "class Hub {\n    var plugin: Plugin?\n    init() {}\n}\n"
                .write(to: hub, atomically: true, encoding: .utf8)
            try "class Plugin {\n    var hub: Hub?\n    init() {}\n}\n"
                .write(to: plugin, atomically: true, encoding: .utf8)
            let store = dir.appending(path: "index")
            try IndexFixture.build(store: store, module: "ArcLeakIndexFixture", files: [hub, plugin], in: dir)

            let resolver = try await IndexStoreTypeResolver.open(
                storePath: store.path, cacheRoot: dir.appending(path: "cache").path, analyzedFiles: [hub.path])

            // The index resolves Plugin as a class with a back-edge to Hub.
            let facts = try #require(resolver.externalTypeFacts(name: "Plugin"))
            #expect(facts.isReferenceType)
            #expect(facts.strongReferences.contains { $0.referencedTypeNames.contains("Hub") })

            // The headline delta: analyze only Hub.swift.
            let withIndex = await Analyzer().analyze(files: [hub.path], index: resolver)
            #expect(withIndex.findings.map(\.rule) == [.mutualStrongProperties])
            let withoutIndex = await Analyzer().analyze(files: [hub.path])
            #expect(withoutIndex.findings.isEmpty)
        }
    }
#endif
