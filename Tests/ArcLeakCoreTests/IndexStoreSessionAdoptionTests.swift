#if os(macOS)
    import Foundation
    import Testing

    /// arcleak opens index stores through analyzerkit's `IndexStoreSession` and finds them with `IndexStoreLocation`
    /// (analyzerkit roadmap 0018 step B, ADR-0004): the database lives under the cache root, never beside the store, and
    /// a store is found wherever a build puts one.
    @Suite(.enabled(if: IndexFixture.available, "needs a swiftc matching libIndexStore.dylib"))
    struct IndexStoreSessionAdoptionTests {
        private static let hub = "class Hub {\n    var plugin: Plugin?\n    init() {}\n}\n"
        private static let plugin = "class Plugin {\n    var hub: Hub?\n    init() {}\n}\n"

        /// A package whose `Hub.swift` is analyzed and whose `Plugin.swift` only the index knows; the store is built
        /// at `store` (relative to the package).
        private static func package(storeAt store: String) throws -> (root: URL, hub: URL) {
            let root = try IndexFixture.directory()
            try "// swift-tools-version: 6.0\n".write(
                to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
            let sources = root.appending(path: "Sources/A")
            let other = root.appending(path: "Other")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let hub = sources.appending(path: "Hub.swift")
            let plugin = other.appending(path: "Plugin.swift")
            try Self.hub.write(to: hub, atomically: true, encoding: .utf8)
            try Self.plugin.write(to: plugin, atomically: true, encoding: .utf8)
            let storeURL = root.appending(path: store)
            try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
            try IndexFixture.build(store: storeURL, module: "A", files: [hub, plugin], in: root)
            return (root, hub)
        }

        @Test func `the index database lives under the cache root, not beside the store`() throws {
            let (root, hub) = try Self.package(storeAt: "store")
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = root.appending(path: "cache")
            let run = try BuiltTool.run(
                [
                    "analyze", hub.path, "--index-store-path", root.appending(path: "store").path, "--cache-path",
                    cache.path,
                ], in: root)

            #expect(run.standardError.contains("index active for 1 of 1 files"), "\(run.standardError)")
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "IndexDatabase").path))
            let databases = (try? FileManager.default.contentsOfDirectory(atPath: cache.appending(path: "index").path))
            #expect(databases?.count == 1, "\(databases ?? [])")
        }

        /// Given a SwiftPM build configuration, the store is the `index/store` below it.
        @Test func `a build directory given as the store resolves to the store below it`() throws {
            let (root, hub) = try Self.package(storeAt: "build/debug/index/store")
            defer { try? FileManager.default.removeItem(at: root) }
            let run = try BuiltTool.run(
                [
                    "analyze", hub.path, "--index-store-path", root.appending(path: "build/debug").path,
                    "--cache-path", root.appending(path: "cache").path,
                ], in: root)

            #expect(run.standardError.contains("index active for 1 of 1 files"), "\(run.standardError)")
            #expect(String(decoding: run.standardOutput, as: UTF8.self).contains("mutual-strong-properties"))
        }

        /// The Swift Build system writes its store to `.build/out`; on Swift 6.4 its units are absolute, and a store of
        /// relative ones is refused by coverage anyway.
        @Test func `discovery finds the store the Swift Build system writes`() throws {
            let (root, hub) = try Self.package(storeAt: ".build/out")
            defer { try? FileManager.default.removeItem(at: root) }
            let run = try BuiltTool.run(
                ["analyze", hub.path, "--index-store", "--cache-path", root.appending(path: "cache").path], in: root)

            #expect(run.standardError.contains("index active for 1 of 1 files"), "\(run.standardError)")
        }
    }
#endif
