#if canImport(IndexStoreDB)
    import Foundation
    import IndexStoreSupport
    import ProjectModel

    /// `--index-store-build`: `swift build` a SwiftPM project that has no store, then find the store it wrote.
    ///
    /// The build runs through analyzerkit's `BoundedProcess` (ADR-0004): a scrubbed environment (no inherited
    /// `DEVELOPER_DIR` or `DYLD_INSERT_LIBRARIES`), a deadline, and a process group that is terminated whole when the
    /// deadline passes, so no compiler is left behind.
    enum IndexStoreAutoBuild {
        struct Result: Sendable {
            let success: Bool
            let output: String
            let indexStorePath: String?
        }

        static let timeout: Duration = .seconds(600)

        static func run(projectRoot: String) async -> Result {
            guard FileManager.default.fileExists(atPath: projectRoot + "/Package.swift") else {
                return Result(
                    success: false,
                    output: "No Package.swift at \(projectRoot); auto-build supports SwiftPM projects only.",
                    indexStorePath: nil)
            }
            let storeRelative = ".build/index/store"
            do {
                let result = try await BoundedProcess.run(
                    "/usr/bin/swift", ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", storeRelative],
                    directory: projectRoot,
                    environment: BoundedProcess.scrubbedEnvironment(source: ProcessInfo.processInfo.environment),
                    timeout: timeout)
                // The Swift Build system ignores `-index-store-path` and writes to `.build/out`: rediscover the store
                // rather than trust the override's target.
                let store =
                    result.succeeded
                    ? (IndexStoreResolution.discover(projectRoot: projectRoot, derivedDataRoots: [])
                        ?? projectRoot + "/" + storeRelative)
                    : nil
                return Result(
                    success: result.succeeded, output: result.standardOutputText + result.standardErrorText,
                    indexStorePath: store)
            } catch {
                return Result(success: false, output: "Failed to run swift build: \(error)", indexStorePath: nil)
            }
        }
    }
#endif
