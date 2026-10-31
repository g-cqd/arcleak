#if os(macOS)
    @testable import ArcLeakCore
    import Foundation
    import IndexStoreSupport
    import SourceCorpus
    import Testing

    /// arcleak reads the store through analyzerkit's `IndexQueries` (roadmap 0054): occurrences come back in the corpus's
    /// spelling, so a store that records `/private/var/…` for a `/var/…` corpus answers in `/var/…`.
    @Suite(.enabled(if: IndexFixture.available, "needs a swiftc matching libIndexStore.dylib"))
    struct IndexQueriesAdoptionTests {
        @Test func `occurrences carry the corpus's spelling of their file`() async throws {
            // Not resolved through links: swiftc is given `/var/folders/…` and the store records `/private/var/…`.
            let directory = FileManager.default.temporaryDirectory.appending(path: "arcleak-iq-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let hub = directory.appending(path: "Hub.swift")
            try "class Hub {\n    init() {}\n}\n".write(to: hub, atomically: true, encoding: .utf8)
            let store = directory.appending(path: "store")
            try IndexFixture.build(store: store, module: "IQ", files: [hub], in: directory)
            let reader = try await IndexStoreReader.open(
                indexStorePath: store.path, cacheRoot: directory.appending(path: "cache").path,
                analyzedFiles: [SourcePath.canonical(hub.path)])
            let definitions = reader.typeDefinitions(ofSymbolNamed: "Hub")
            #expect(definitions.map(\.file) == [SourcePath.canonical(hub.path)])
            #expect(
                reader.findOccurrences(ofSymbolNamed: "Hub").allSatisfy { $0.file == SourcePath.canonical($0.file) })
        }
    }
#endif
