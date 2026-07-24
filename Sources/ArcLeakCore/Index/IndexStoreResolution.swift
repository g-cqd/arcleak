/// Front door the CLI uses to (optionally) obtain an index-backed type
/// resolver. Always safe to call and NEVER throws: on a platform without
/// IndexStoreDB, or when no store can be found / built / opened, or when the
/// store is stale relative to the corpus, it returns a nil index and a
/// human-readable note explaining the fallback. The index is a pure supplement;
/// a nil index means today's corpus-only analysis, byte-identical.
public enum IndexStoreResolution {
    public struct Outcome: Sendable {
        /// The resolver to hand to `Analyzer.analyze(…, index:)`, or nil to run
        /// corpus-only.
        public let index: (any IndexReading)?
        /// A note to surface to the user (fallback reason, or the active store
        /// path). Nil when there is nothing to say.
        public let note: String?

        public init(index: (any IndexReading)?, note: String?) {
            self.index = index
            self.note = note
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
        defines: Set<String>
    ) async -> Outcome {
        #if canImport(IndexStoreDB)
            return await resolveWithIndexStore(
                projectRoot: projectRoot,
                explicitStorePath: explicitStorePath,
                autoBuild: autoBuild,
                analyzedFiles: analyzedFiles,
                defines: defines
            )
        #else
            return Outcome(
                index: nil,
                note: "index store support is macOS-only; proceeding with corpus-only analysis"
            )
        #endif
    }

    #if canImport(IndexStoreDB)
        private static func resolveWithIndexStore(
            projectRoot: String,
            explicitStorePath: String?,
            autoBuild: Bool,
            analyzedFiles: [String],
            defines: Set<String>
        ) async -> Outcome {
            var storePath = explicitStorePath ?? IndexStorePathFinder.findIndexStorePath(in: projectRoot)
            var freshlyBuilt = false

            if storePath == nil, autoBuild {
                let manager = IndexStoreFallbackManager(configuration: .withAutoBuild)
                let result = await manager.autoBuild(projectRoot: projectRoot)
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

            let resolver: IndexStoreTypeResolver
            do {
                resolver = try await IndexStoreTypeResolver.open(storePath: storePath, defines: defines)
            } catch {
                return Outcome(
                    index: nil,
                    note:
                        "index store at \(storePath) could not be opened (\(error)); "
                        + "proceeding with corpus-only analysis"
                )
            }

            // Staleness contract AND crash-safety gate. A store older than an
            // analyzed source could resolve to wrong facts — downgrade to
            // corpus-only with a notice, never silently wrong. This also runs
            // unconditionally (even for a just-built store) because it is the
            // guard that keeps a relative-unit-path store from ever reaching a
            // symbol query: absolute analyzed paths don't match relative units,
            // so such a store reports fully stale and is downgraded here, before
            // any query can abort libIndexStore.
            let stale = resolver.staleFiles(among: analyzedFiles)
            if !stale.isEmpty {
                let reason =
                    freshlyBuilt
                    ? "the auto-built index does not cover \(stale.count) analyzed file(s)"
                    : "index store at \(storePath) is stale for \(stale.count) analyzed file(s)"
                return Outcome(
                    index: nil,
                    note: "\(reason); proceeding with corpus-only analysis"
                )
            }

            return Outcome(index: resolver, note: "index store active: \(storePath)")
        }

        private static func firstLine(_ text: String) -> String {
            text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        }
    #endif
}
