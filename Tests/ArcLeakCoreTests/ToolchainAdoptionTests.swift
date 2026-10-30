import Foundation
import Testing

@testable import ArcLeakCore

#if canImport(IndexStoreDB)
    import IndexStoreSupport
#endif

@Suite struct ToolchainAdoptionTests {
    #if canImport(IndexStoreDB)
        @Test func `tool trust resolves links and rejects a writable immediate parent`() throws {
            let root = try Workspace.make(["lib/libIndexStore.dylib": "not loaded"])
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appending(path: "lib/libIndexStore.dylib").resolvingSymlinksInPath().path
            let parent = URL(fileURLWithPath: target).deletingLastPathComponent().path
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
            let link = root.appending(path: "linked.dylib").path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            #expect(BinaryTrustChecker.isTrusted(at: link))
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: parent)
            #expect(!BinaryTrustChecker.isTrusted(at: target))
        }

        @Test func `explicit untrusted library is rejected before opening the store`() throws {
            let cache = try Workspace.make([:])
            defer { try? FileManager.default.removeItem(at: cache) }
            let root = try Workspace.make(["lib/untrusted.dylib": "not a library"])
            defer { try? FileManager.default.removeItem(at: root) }
            let library = root.appending(path: "lib/untrusted.dylib").path
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: library)
            do {
                try FileManager.default.createDirectory(
                    at: root.appending(path: "Store/v5/records"), withIntermediateDirectories: true)
                try Data().write(to: root.appending(path: "Store/v5/records/r"))
                _ = try IndexStoreReader.open(
                    indexStorePath: root.appending(path: "Store").path, cacheRoot: cache.path, library: library,
                    analyzedFiles: [])
                Issue.record("opened a reader using an untrusted library")
            } catch IndexStoreError.failedToOpen(let reason) {
                // Rejected before any IndexStoreDB filesystem or dlopen work.
                #expect(reason.contains("not trusted"), "\(reason)")
            } catch {
                Issue.record("wrong rejection: \(error)")
            }
            #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "index").path))
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "IndexDatabase").path))
        }
    #endif

    @Test func `verbose index diagnostics stay on stderr and do not change the report`() throws {
        let root = try Workspace.make([
            ".git": "gitdir: elsewhere", "Sources/A.swift": "struct A {}\n", "NotAStore/empty": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = [
            "analyze", root.path, "--format", "json", "--no-cache", "--index-store-path",
            root.appending(path: "NotAStore").path,
        ]
        let normal = try BuiltTool.run(arguments, in: root)
        let verbose = try BuiltTool.run(arguments + ["--verbose"], in: root)
        #expect(verbose.status == normal.status)
        #expect(verbose.standardOutput == normal.standardOutput)
        #if os(macOS)
            #expect(verbose.standardError.contains("libIndexStore:"))
        #else
            #expect(verbose.standardError.contains("macOS-only"))
        #endif
        #expect(!normal.standardError.contains("libIndexStore:"))
    }
}
