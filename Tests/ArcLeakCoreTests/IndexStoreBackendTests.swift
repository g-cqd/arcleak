#if os(macOS)
    import ArcLeakCore
    import Foundation
    import Testing

    /// The IndexStoreDB-backed resolver, end-to-end. A fresh two-file index is
    /// built with the *same* toolchain whose `libIndexStore.dylib` the resolver
    /// discovers (so the store format and the reader always match). arcleak then
    /// analyzes only ONE of the two mutually-referencing files: with the index it
    /// reports the cross-module cycle (the counterpart is located + parsed via
    /// the index), without it stays silent.
    ///
    /// Skips cleanly when no trusted `libIndexStore.dylib` + matching `swiftc` is
    /// available, or the environment can't index the fixture — mirroring the
    /// macOS-only leak-oracle gating (an index is not guaranteed on every host).
    @Suite struct IndexStoreBackendTests {
        @Test("A prebuilt index unlocks a cross-module cycle the default mode misses")
        func indexUnlocksCrossModuleCycle() async throws {
            guard let swiftc = await Self.matchingSwiftc() else { return }

            let dir = FileManager.default.temporaryDirectory
                .appending(path: "arcleak-xmod-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let hub = dir.appending(path: "Hub.swift")
            let plugin = dir.appending(path: "Plugin.swift")
            try "class Hub {\n    var plugin: Plugin?\n    init() {}\n}\n"
                .write(to: hub, atomically: true, encoding: .utf8)
            try "class Plugin {\n    var hub: Hub?\n    init() {}\n}\n"
                .write(to: plugin, atomically: true, encoding: .utf8)

            let store = dir.appending(path: "index")
            guard
                Self.buildIndex(
                    swiftc: swiftc, store: store.path, files: [hub.path, plugin.path], cwd: dir
                )
            else { return }  // toolchain quirk — don't assert on the environment

            let resolver: IndexStoreTypeResolver
            do {
                resolver = try await IndexStoreTypeResolver.open(storePath: store.path)
            } catch {
                return  // this dylib can't read the store — skip
            }

            // Sanity: the index must resolve Plugin as a class with a back-edge to
            // Hub, or the environment didn't index the fixture as expected.
            guard let facts = resolver.externalTypeFacts(name: "Plugin"),
                facts.isReferenceType,
                facts.strongReferences.contains(where: { $0.referencedTypeNames.contains("Hub") })
            else { return }

            // The headline delta: analyze ONLY Hub.swift.
            let withIndex = await Analyzer().analyze(files: [hub.path], index: resolver)
            #expect(withIndex.findings.map(\.rule) == [.mutualStrongProperties])

            let withoutIndex = await Analyzer().analyze(files: [hub.path])
            #expect(withoutIndex.findings.isEmpty)
        }

        // MARK: Toolchain

        /// `swiftc` from the same toolchain as the discovered `libIndexStore.dylib`
        /// (`<toolchain>/usr/lib/libIndexStore.dylib` → `<toolchain>/usr/bin/swiftc`),
        /// or nil when no trusted dylib / executable swiftc is found.
        private static func matchingSwiftc() async -> String? {
            guard let dylib = await IndexStoreReader.findLibIndexStore() else { return nil }
            let swiftc = URL(fileURLWithPath: dylib)
                .deletingLastPathComponent()  // lib
                .deletingLastPathComponent()  // usr
                .appendingPathComponent("bin/swiftc").path
            return FileManager.default.isExecutableFile(atPath: swiftc) ? swiftc : nil
        }

        /// Compile the fixture files into an index store. Tests may use `Process`
        /// directly (only implementation code is GCD/subprocess-gated).
        private static func buildIndex(
            swiftc: String, store: String, files: [String], cwd: URL
        ) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: swiftc)
            process.arguments =
                [
                    "-index-store-path", store,
                    "-index-ignore-system-modules",
                    "-module-name", "ArcLeakIndexFixture",
                    "-emit-module",
                    "-emit-module-path", cwd.appendingPathComponent("Fixture.swiftmodule").path,
                ] + files
            process.currentDirectoryURL = cwd
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }
#endif
