#if os(macOS)
    @testable import ArcLeakCore
    import Foundation
    import ReportSupport
    import Testing

    /// The index decided per definition, not per run (analyzerkit ADR-0005, roadmap 0023): probes A1, A3, A4 and A8 of
    /// `index-fixtures.sh` as tests.
    @Suite(.enabled(if: IndexFixture.available, "needs a swiftc matching libIndexStore.dylib"))
    struct IndexPerDefinitionTests {
        private static let hub = "class Hub {\n    var plugin: Plugin?\n    init() {}\n}\n"
        private static let plugin = "class Plugin {\n    var hub: Hub?\n    init() {}\n}\n"

        private static func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        private static func resolve(_ files: [URL], store: URL, in directory: URL) async -> IndexStoreResolution.Outcome
        {
            await IndexStoreResolution.resolve(
                projectRoot: directory.path, explicitStorePath: store.path, autoBuild: false,
                analyzedFiles: files.map(\.path), defines: [], cacheRoot: directory.appending(path: "cache").path)
        }

        private static func rules(_ files: [URL], _ outcome: IndexStoreResolution.Outcome) async -> [RuleID] {
            await Analyzer().analyze(files: files.map(\.path), index: outcome.index).findings.map(\.rule)
        }

        /// A1: a file the build never compiled no longer drops the index for the run.
        @Test func `a never-compiled analyzed file leaves the index active for the others`() async throws {
            let directory = try IndexFixture.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let hub = directory.appending(path: "src/Hub.swift")
            let plugin = directory.appending(path: "ext/Plugin.swift")
            try Self.write(Self.hub, to: hub)
            try Self.write(Self.plugin, to: plugin)
            let store = directory.appending(path: "store")
            try IndexFixture.build(store: store, module: "A1", files: [hub, plugin], in: directory)
            let script = directory.appending(path: "src/Script.swift")
            try Self.write("let x = 1\n", to: script)

            let outcome = await Self.resolve([hub, script], store: store, in: directory)
            #expect(outcome.index != nil, "\(outcome.note ?? "no note")")
            #expect(
                outcome.note?.contains("index active for 1 of 2 files; 1 not in the index, 0 changed since the build")
                    == true, "\(outcome.note ?? "no note")")
            #expect(await Self.rules([hub, script], outcome) == [.mutualStrongProperties])

            // A8: the uncovered file is a run note with its path, and a skipped file of the index.
            #expect(outcome.runNotes.contains { $0.code == "index-not-indexed" && $0.paths == [script.path] })
            #expect(outcome.skippedFiles.map(\.path) == [script.path])
        }

        /// A3: two modules declare `Coordinator`, a struct and a class with a back-edge. The answer must not depend on
        /// which definition the index lists first: definitions that disagree answer nothing.
        @Test func `same-named types that disagree answer nothing`() async throws {
            let directory = try IndexFixture.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let value = directory.appending(path: "m1/Coordinator.swift")
            let reference = directory.appending(path: "m2/Coordinator.swift")
            let owner = directory.appending(path: "c1/Owner.swift")
            try Self.write("public struct Coordinator { public init() {} }\n", to: value)
            try Self.write("public class Coordinator {\n    var owner: Owner?\n    init() {}\n}\n", to: reference)
            try Self.write("class Owner {\n    var c: Coordinator?\n}\n", to: owner)
            let both = directory.appending(path: "s1")
            try IndexFixture.build(store: both, module: "M1", files: [value], in: directory)
            try IndexFixture.build(store: both, module: "M2", files: [reference, owner], in: directory)
            let one = directory.appending(path: "s2")
            try IndexFixture.build(store: one, module: "M2", files: [reference, owner], in: directory)

            let control = await Self.resolve([owner], store: one, in: directory)
            #expect(await Self.rules([owner], control) == [.mutualStrongProperties], "\(control.note ?? "")")
            let ambiguous = await Self.resolve([owner], store: both, in: directory)
            #expect(ambiguous.index != nil)
            #expect(await Self.rules([owner], ambiguous).isEmpty)
        }

        /// A4: a declaring file edited since the build is not `indexed`, so nothing is taken from its record, even
        /// when it still declares the type.
        @Test func `a declaring file changed since the build answers nothing`() async throws {
            let directory = try IndexFixture.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let hub = directory.appending(path: "src/Hub.swift")
            let plugin = directory.appending(path: "ext/Plugin.swift")
            try Self.write(Self.hub, to: hub)
            try Self.write(Self.plugin, to: plugin)
            let store = directory.appending(path: "store")
            try IndexFixture.build(store: store, module: "A4", files: [hub, plugin], in: directory)
            try Self.write("// edited\n" + Self.plugin, to: plugin)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: plugin.path)

            let outcome = await Self.resolve([hub], store: store, in: directory)
            #expect(outcome.index != nil)
            #expect(await Self.rules([hub], outcome).isEmpty)
        }
    }
#endif
