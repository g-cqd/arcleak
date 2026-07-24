#if canImport(IndexStoreDB)
    public import Foundation

    // MARK: - IndexStoreStatus

    /// Status of the index store for analysis.
    public enum IndexStoreStatus: Sendable {
        /// Index store exists and is up-to-date.
        case available(path: String)
        /// Index store exists but is stale (source files modified after index).
        case stale(path: String, staleFiles: [String])
        /// Index store does not exist.
        case notFound
        /// Index store exists but failed to open.
        case failed(error: String)

        /// Whether the index is usable (available, or stale with warnings).
        public var isUsable: Bool {
            switch self {
            case .available, .stale: true
            case .failed, .notFound: false
            }
        }

        /// The path to the index store, if any.
        public var path: String? {
            switch self {
            case .available(let path), .stale(let path, _): path
            case .failed, .notFound: nil
            }
        }
    }

    // MARK: - BuildResult

    /// Result of attempting to build the project to (re)generate the store.
    public struct BuildResult: Sendable {
        public let success: Bool
        public let output: String
        public let duration: TimeInterval
        public let indexStorePath: String?

        public init(success: Bool, output: String, duration: TimeInterval, indexStorePath: String?) {
            self.success = success
            self.output = output
            self.duration = duration
            self.indexStorePath = indexStorePath
        }
    }

    // MARK: - FallbackConfiguration

    /// Configuration for index availability / fallback behaviour. Trimmed from
    /// SwiftStaticAnalysis to arcleak's needs — the reachability-mode and
    /// hybrid-mode machinery (and its `AnalysisLogger`/sandbox plumbing) is not
    /// lifted, because arcleak does not do reachability analysis.
    public struct FallbackConfiguration: Sendable {
        /// Automatically `swift build` the project when the index is missing.
        public var autoBuild: Bool
        /// Compare source mtimes against the store and report stale files.
        public var checkFreshness: Bool

        public init(autoBuild: Bool = false, checkFreshness: Bool = true) {
            self.autoBuild = autoBuild
            self.checkFreshness = checkFreshness
        }

        public static let `default` = Self()
        public static let withAutoBuild = Self(autoBuild: true)
    }

    // MARK: - IndexStoreFallbackManager

    /// Manages index-store discovery, freshness, and (opt-in) auto-build.
    public struct IndexStoreFallbackManager: Sendable {
        public let configuration: FallbackConfiguration
        private let libIndexStorePath: String?

        public init(configuration: FallbackConfiguration = .default, libIndexStorePath: String? = nil) {
            self.configuration = configuration
            self.libIndexStorePath = libIndexStorePath
        }

        // MARK: Status

        /// Check the status of the index store for a project.
        public func checkIndexStoreStatus(
            projectRoot: String,
            sourceFiles: [String]
        ) async -> IndexStoreStatus {
            guard let storePath = IndexStorePathFinder.findIndexStorePath(in: projectRoot) else {
                return .notFound
            }
            let reader: IndexStoreReader
            do {
                reader = try await openReader(storePath: storePath)
            } catch {
                return .failed(error: "\(error)")
            }
            if configuration.checkFreshness {
                let stale = staleFiles(sourceFiles: sourceFiles, reader: reader)
                if !stale.isEmpty {
                    return .stale(path: storePath, staleFiles: stale)
                }
            }
            return .available(path: storePath)
        }

        // MARK: Auto build

        /// `swift build` the SwiftPM project to generate/update the store. The
        /// child runs under `ProcessExecutor`'s scrubbed environment (no
        /// inherited `DEVELOPER_DIR` / `DYLD_INSERT_LIBRARIES`).
        public func autoBuild(projectRoot: String) async -> BuildResult {
            let start = Date()
            let projectURL = URL(fileURLWithPath: projectRoot)
            guard
                FileManager.default.fileExists(
                    atPath: projectURL.appendingPathComponent("Package.swift").path
                )
            else {
                return BuildResult(
                    success: false,
                    output: "No Package.swift at \(projectRoot); auto-build supports SwiftPM projects only.",
                    duration: Date().timeIntervalSince(start),
                    indexStorePath: nil
                )
            }
            let storeRelative = ".build/index/store"
            do {
                let result = try await ProcessExecutor.run(
                    executable: URL(fileURLWithPath: "/usr/bin/swift"),
                    arguments: [
                        "build", "-Xswiftc", "-index-store-path",
                        "-Xswiftc", storeRelative,
                    ],
                    currentDirectory: projectURL,
                    timeout: .seconds(600)
                )
                // The `-index-store-path` override is honored by the classic
                // build system but ignored by the current Swift Build system
                // (which writes to `.build/out`), so rediscover the real store
                // rather than trusting the override target.
                let store =
                    result.succeeded
                    ? (IndexStorePathFinder.findIndexStorePath(in: projectRoot)
                        ?? projectURL.appendingPathComponent(storeRelative).path)
                    : nil
                return BuildResult(
                    success: result.succeeded,
                    output: result.stdout + result.stderr,
                    duration: Date().timeIntervalSince(start),
                    indexStorePath: store
                )
            } catch {
                return BuildResult(
                    success: false,
                    output: "Failed to run swift build: \(error)",
                    duration: Date().timeIntervalSince(start),
                    indexStorePath: nil
                )
            }
        }

        // MARK: Helpers

        private func openReader(storePath: String) async throws(IndexStoreError) -> IndexStoreReader {
            if let libIndexStorePath {
                return try IndexStoreReader(indexStorePath: storePath, libIndexStorePath: libIndexStorePath)
            }
            return try await IndexStoreReader.open(indexStorePath: storePath)
        }

        /// Source files whose on-disk mtime is newer than the index's latest
        /// unit for them (or that the index has never seen).
        private func staleFiles(sourceFiles: [String], reader: IndexStoreReader) -> [String] {
            var stale: [String] = []
            for file in sourceFiles {
                guard
                    let attributes = try? FileManager.default.attributesOfItem(atPath: file),
                    let sourceDate = attributes[.modificationDate] as? Date
                else { continue }
                guard let unitDate = reader.latestUnitDate(forFile: file) else {
                    stale.append(file)
                    continue
                }
                if sourceDate > unitDate {
                    stale.append(file)
                }
            }
            return stale
        }
    }
#endif
