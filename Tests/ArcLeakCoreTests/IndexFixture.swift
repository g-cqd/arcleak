#if os(macOS)
    @testable import ArcLeakCore
    import Foundation

    /// Real index stores built by the `swiftc` of the toolchain whose `libIndexStore.dylib` arcleak loads, so the store
    /// format and the reader always match. `-emit-module` matters: a `-typecheck` build records no per-file units.
    enum IndexFixture {
        /// The matching `swiftc`, or nil on a host without a trusted toolchain.
        /// From `xcrun`, which selects as analyzerkit's `ToolchainResolution` does (`DEVELOPER_DIR`, then
        /// `xcode-select`); that resolution is async and a static initializer is not.
        static let swiftc: String? = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["--find", "swiftc"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let swiftc = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: swiftc) ? swiftc : nil
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
