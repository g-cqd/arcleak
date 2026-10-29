#if os(macOS)
    @testable import ArcLeakCore
    import Foundation

    /// Real index stores built by the `swiftc` of the toolchain whose `libIndexStore.dylib` arcleak loads, so the store
    /// format and the reader always match. `-emit-module` matters: a `-typecheck` build records no per-file units.
    enum IndexFixture {
        /// The matching `swiftc`, or nil on a host without a trusted toolchain.
        static let swiftc: String? = {
            guard let dylib = IndexStoreReader.resolveLibraryPathSync() else { return nil }
            let swiftc = URL(fileURLWithPath: dylib).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("bin/swiftc").path
            return FileManager.default.isExecutableFile(atPath: swiftc) ? swiftc : nil
        }()

        static var available: Bool { swiftc != nil }

        /// Compiles `files` as module `module`, recording the index into `store`.
        static func build(store: URL, module: String, files: [URL], in directory: URL) throws {
            guard let swiftc else { throw CocoaError(.featureUnsupported) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: swiftc)
            process.arguments =
                [
                    "-index-store-path", store.path, "-index-ignore-system-modules", "-module-name", module,
                    "-parse-as-library", "-emit-module",
                    "-emit-module-path", directory.appendingPathComponent("\(module).swiftmodule").path,
                ] + files.map(\.path)
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        }

        /// A fresh directory under the temporary directory, resolved through symbolic links (`/private/var`).
        static func directory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "arcleak-index-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.resolvingSymlinksInPath()
        }
    }
#endif
