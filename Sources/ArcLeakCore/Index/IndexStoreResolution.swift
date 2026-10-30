public import ReportSupport

#if canImport(IndexStoreDB)
    import Foundation
    import IndexStoreSupport
    import ProjectModel
#endif

/// Front door the CLI uses to (optionally) obtain an index-backed type
/// resolver. Always safe to call and NEVER throws: on a platform without
/// IndexStoreDB, or when no store can be found / built / opened, or when the
/// store indexes none of the analyzed files, it returns a nil index and a
/// human-readable note explaining the fallback. Freshness is decided per
/// definition, not per run (ADR-0005): files the store does not cover are
/// listed, and the index answers for the rest. The index is a pure supplement;
/// a nil index means today's corpus-only analysis, byte-identical.
public enum IndexStoreResolution {
    public struct Outcome: Sendable {
        /// The resolver to hand to `Analyzer.analyze(…, index:)`, or nil to run
        /// corpus-only.
        public let index: (any IndexReading)?
        /// A note to surface to the user (fallback reason, or the active store
        /// path). Nil when there is nothing to say.
        public let note: String?
        /// What the report says of the store's coverage of the analyzed files (ADR-0017): one note per class of file it
        /// does not cover, or one that it was not used. Every path is listed; the report shortens them unless verbose.
        public let runNotes: [RunNote]
        /// The analyzed files the store does not cover, as the report lists them.
        public let skippedFiles: [SkippedFile]

        public init(
            index: (any IndexReading)?, note: String?, runNotes: [RunNote] = [], skippedFiles: [SkippedFile] = []
        ) {
            self.index = index
            self.note = note
            self.runNotes = runNotes
            self.skippedFiles = skippedFiles
        }
    }

    /// Resolve an index-backed type resolver for `analyzedFiles`, or explain the
    /// fallback. `explicitStorePath` (from `--index-store-path`) wins over
    /// discovery; `autoBuild` (from `--index-store-build`) permits a
    /// `swift build` when no store is found.
    public static func resolve(
        projectRoot: String,
        explicitStorePath: String?,
        autoBuild: Bool,
        analyzedFiles: [String],
        defines: Set<String>,
        cacheRoot: String
    ) async -> Outcome {
        #if canImport(IndexStoreDB)
            return await resolveWithIndexStore(
                projectRoot: projectRoot,
                explicitStorePath: explicitStorePath,
                autoBuild: autoBuild,
                analyzedFiles: analyzedFiles,
                defines: defines,
                cacheRoot: cacheRoot
            )
        #else
            return Outcome(
                index: nil,
                note: "index store support is macOS-only; proceeding with corpus-only analysis"
            )
        #endif
    }

    #if canImport(IndexStoreDB)
        /// The store a project has: SwiftPM's under its `.build`, then the newest DerivedData store of its containers
        /// (analyzerkit `IndexStoreLocation`).
        static func discover(projectRoot: String, derivedDataRoots: [String]? = nil) -> String? {
            guard let layout = ProjectLayout.discover(paths: [projectRoot]) else { return nil }
            let roots =
                derivedDataRoots ?? [
                    (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
                        + "/Library/Developer/Xcode/DerivedData"
                ]
            return IndexStoreLocation.discover(layout: layout, derivedDataRoots: roots)
        }

        private static func resolveWithIndexStore(
            projectRoot: String,
            explicitStorePath: String?,
            autoBuild: Bool,
            analyzedFiles: [String],
            defines: Set<String>,
            cacheRoot: String
        ) async -> Outcome {
            var storePath = explicitStorePath ?? discover(projectRoot: projectRoot)
            var freshlyBuilt = false

            if storePath == nil, autoBuild {
                let result = await IndexStoreAutoBuild.run(projectRoot: projectRoot)
                guard result.success, let built = result.indexStorePath else {
                    return Outcome(
                        index: nil,
                        note:
                            "index-store auto-build failed; proceeding with corpus-only analysis "
                            + "(\(firstLine(result.output)))"
                    )
                }
                storePath = built
                freshlyBuilt = true
            }

            guard let storePath else {
                let hint =
                    autoBuild
                    ? "" : " (pass --index-store-build to build one, or --index-store-path <dir>)"
                return Outcome(
                    index: nil,
                    note:
                        "no index store found under \(projectRoot)\(hint); "
                        + "proceeding with corpus-only analysis"
                )
            }

            // A path that is not a store is refused before anything opens it: libIndexStore would create a `v5/` in
            // it (analyzerkit roadmap 0035, probe A6). The database lives under the cache root, never beside the store.
            let resolver: IndexStoreTypeResolver
            do {
                resolver = try await IndexStoreTypeResolver.open(
                    storePath: storePath, cacheRoot: cacheRoot, analyzedFiles: analyzedFiles, defines: defines)
            } catch .notAStore(let reason) {
                return Outcome(index: nil, note: "\(reason); proceeding with corpus-only analysis")
            } catch .coversNoAnalyzedFile(let store, let count, let coverage) {
                // The run-wide gate's one job (ADR-0005 item 2): no analyzed file is indexed, so the store does not
                // describe these files; this also keeps a store of relative unit paths from any symbol query.
                return Outcome(
                    index: nil, note: Self.staleNote(store: store, count: count, freshlyBuilt: freshlyBuilt),
                    runNotes: coverage.runNotes(store: store, verbose: true), skippedFiles: coverage.skippedFiles)
            } catch {
                return Outcome(
                    index: nil,
                    note:
                        "index store at \(storePath) could not be opened (\(error)); "
                        + "proceeding with corpus-only analysis"
                )
            }

            // Files the store does not cover are listed, and the index answers for the others: a type's answer depends
            // on the freshness of the file that declares it, which the resolver checks (ADR-0005).
            let coverage = resolver.coverage
            let indexed = coverage.paths(.indexed).count
            let missing = coverage.paths(.notIndexed).count
            let changed = coverage.paths(.changedSinceBuild).count
            let note =
                "index active for \(indexed) of \(coverage.files.count) files; \(missing) not in the index, \(changed) "
                + "changed since the build: \(resolver.storePath)"
            return Outcome(
                index: resolver, note: note, runNotes: coverage.runNotes(store: resolver.storePath, verbose: true),
                skippedFiles: coverage.skippedFiles)
        }

        private static func staleNote(store: String, count: Int, freshlyBuilt: Bool) -> String {
            let reason =
                freshlyBuilt
                ? "the auto-built index does not cover \(count) analyzed file(s)"
                : "index store at \(store) is stale for \(count) analyzed file(s)"
            return "\(reason); proceeding with corpus-only analysis"
        }

        private static func firstLine(_ text: String) -> String {
            text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        }
    #endif
}
