import ArcLeakCore
import Foundation
import Testing

/// The index never overrides what the corpus says, never answers from a declaration that is gone, and never writes into a
/// path that is not an index store (analyzerkit roadmap 0035, probes A2, A4, A6).
@Suite struct IndexWaveZeroTests {
    struct FakeIndex: IndexReading {
        let types: [String: ExternalTypeFacts]
        func externalTypeFacts(name: String) -> ExternalTypeFacts? { types[name] }
    }

    /// An index that says `name` is a class holding a strong reference back to `Hub`.
    private static func classWithBackEdge(_ name: String) -> FakeIndex {
        FakeIndex(types: [
            name: ExternalTypeFacts(
                isReferenceType: true,
                strongReferences: [
                    ExternalStrongReference(
                        property: "hub", referencedTypeNames: ["Hub"], position: SourcePosition(line: 2, column: 5))
                ],
                declaringPath: "Elsewhere/\(name).swift")
        ])
    }

    @Test func `a type the corpus declares as a struct is never looked up in the index`() {
        let source = "class Hub {\n    var plugin: Plugin?\n}\nstruct Plugin {\n    var x = 0\n}\n"
        let findings = Analyzer().analyze(source: source, path: "Hub.swift", index: Self.classWithBackEdge("Plugin"))
            .findings
        #expect(findings.isEmpty, "\(findings.map(\.rule))")
    }

    @Test func `an extension of a struct the corpus declares in another file is not made a class by the index`()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appending(path: "arcleak-a2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let declaration = directory.appending(path: "Foo.swift")
        let extensionFile = directory.appending(path: "Foo+Arm.swift")
        try "struct Foo {\n    var handler: (() -> Void)?\n    func fire() {}\n}\n"
            .write(to: declaration, atomically: true, encoding: .utf8)
        try "extension Foo {\n    mutating func arm() {\n        self.handler = { self.fire() }\n    }\n}\n"
            .write(to: extensionFile, atomically: true, encoding: .utf8)
        let index = FakeIndex(types: ["Foo": ExternalTypeFacts(isReferenceType: true)])
        let report = await Analyzer().analyze(files: [declaration.path, extensionFile.path], index: index)
        #expect(report.findings.isEmpty, "\(report.findings.map(\.rule))")
    }

    #if os(macOS)
        @Test(.enabled(if: IndexFixture.available, "needs a swiftc matching libIndexStore.dylib"))
        func `a type whose declaring file no longer declares it is not taken for a class`() async throws {
            let directory = try IndexFixture.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let ext = directory.appending(path: "src/Ext.swift")
            let old = directory.appending(path: "ext/Old.swift")
            for url in [ext, old] {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try "extension Plugin {\n    func arm() {\n        self.handler = { self.fire() }\n    }\n}\n"
                .write(to: ext, atomically: true, encoding: .utf8)
            try "class Plugin {\n    var handler: (() -> Void)?\n    func fire() {}\n}\n"
                .write(to: old, atomically: true, encoding: .utf8)
            let store = directory.appending(path: "store")
            try IndexFixture.build(store: store, module: "A4", files: [ext, old], in: directory)

            // While the class is where the index says, the extension's capture is a cycle: the control.
            let before = await Analyzer().analyze(
                files: [ext.path],
                index: try await IndexStoreTypeResolver.open(
                    storePath: store.path, cacheRoot: directory.appending(path: "cache").path,
                    analyzedFiles: [ext.path]))
            #expect(before.findings.map(\.rule) == [.storedClosureStrongSelf])

            // Then the type leaves that file and becomes a struct in a file the index has never seen.
            try "// moved\n".write(to: old, atomically: true, encoding: .utf8)
            try "struct Plugin {\n    var handler: (() -> Void)?\n    func fire() {}\n}\n"
                .write(to: directory.appending(path: "ext/New.swift"), atomically: true, encoding: .utf8)
            let after = await Analyzer().analyze(
                files: [ext.path],
                index: try await IndexStoreTypeResolver.open(
                    storePath: store.path, cacheRoot: directory.appending(path: "cache").path,
                    analyzedFiles: [ext.path]))
            #expect(after.findings.isEmpty, "\(after.findings.map(\.rule)) from a declaration that is gone")
        }

        @Test func `a path that is not an index store is refused, and nothing is created in it`() async throws {
            let directory = try IndexFixture.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let given = directory.appending(path: "DerivedData")
            try FileManager.default.createDirectory(at: given, withIntermediateDirectories: true)
            let outcome = await IndexStoreResolution.resolve(
                projectRoot: directory.path, explicitStorePath: given.path, autoBuild: false,
                analyzedFiles: [], defines: [], cacheRoot: directory.appending(path: "cache").path)
            #expect(outcome.index == nil)
            #expect(outcome.note?.contains("not an index store") == true, "\(outcome.note ?? "no note")")
            let created =
                try FileManager.default.contentsOfDirectory(atPath: given.path)
                + FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
                    $0 != "DerivedData" && $0 != "cache"
                }
            #expect(created.isEmpty, "created \(created)")
        }
    #endif
}
