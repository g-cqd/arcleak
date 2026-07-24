#if canImport(IndexStoreDB)
    import Foundation

    /// Index-store-backed ``IndexReading``: resolves types declared *outside* the
    /// analyzed corpus. IndexStoreDB supplies the symbol KIND (class/actor →
    /// reference type) and the declaring file; arcleak's own extractor then
    /// parses that file for the type's strong stored-property edges. Nothing is
    /// guessed — a name the index does not know resolves to `nil` (the consumer
    /// degrades to silence), and a confirmed value type resolves to
    /// `isReferenceType: false`.
    ///
    /// `@unchecked Sendable`: the underlying reader is documented thread-safe for
    /// reads, and the resolution memo is guarded by an `NSLock` (no GCD). Results
    /// are memoized by name — the concurrent per-file phase and the single-thread
    /// corpus phase both call in.
    public final class IndexStoreTypeResolver: IndexReading, @unchecked Sendable {
        private let reader: IndexStoreReader
        private let defines: Set<String>
        private let memoLock = NSLock()
        private var memo: [String: ExternalTypeFacts?] = [:]
        /// Source files larger than this are not parsed for external edges.
        private static let sourceByteCap = 10 * 1024 * 1024

        public init(reader: IndexStoreReader, defines: Set<String> = []) {
            self.reader = reader
            self.defines = defines
        }

        /// Open a resolver at `storePath`, discovering `libIndexStore.dylib`
        /// asynchronously (see ``IndexStoreReader/open(indexStorePath:allowsDirectoryCreation:)``).
        public static func open(
            storePath: String,
            defines: Set<String> = []
        ) async throws(IndexStoreError) -> IndexStoreTypeResolver {
            let reader = try await IndexStoreReader.open(indexStorePath: storePath)
            return IndexStoreTypeResolver(reader: reader, defines: defines)
        }

        /// Analyzed files the index has never seen (by absolute path), or whose
        /// on-disk mtime is newer than the index's latest unit for them. A
        /// non-empty result means the store is stale relative to the corpus — the
        /// caller downgrades to corpus-only, never resolving against a store that
        /// could be wrong.
        ///
        /// Paths are resolved to absolute+canonical form first. This is also the
        /// safety gate for stores that record RELATIVE unit paths (the current
        /// Swift Build system's `.build/out`): absolute analyzed paths never
        /// match relative units, so such a store reports every file stale and is
        /// downgraded *before* any symbol query runs — that query aborts an
        /// asserts/`report_fatal_error` build of libIndexStore on a relative path.
        public func staleFiles(among files: [String]) -> [String] {
            var stale: [String] = []
            for file in files {
                let absolute = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
                guard
                    let attributes = try? FileManager.default.attributesOfItem(atPath: absolute),
                    let sourceDate = attributes[.modificationDate] as? Date
                else {
                    stale.append(file)
                    continue
                }
                guard let unitDate = reader.latestUnitDate(forFile: absolute) else {
                    stale.append(file)
                    continue
                }
                if sourceDate > unitDate { stale.append(file) }
            }
            return stale
        }

        public func externalTypeFacts(name: String) -> ExternalTypeFacts? {
            memoLock.lock()
            if let cached = memo[name] {
                memoLock.unlock()
                return cached
            }
            memoLock.unlock()

            let resolved = resolve(name: name)

            memoLock.lock()
            memo[name] = resolved
            memoLock.unlock()
            return resolved
        }

        private func resolve(name: String) -> ExternalTypeFacts? {
            guard let definition = reader.definition(ofSymbolNamed: name) else {
                return nil  // the index doesn't know this name — degrade to silence
            }
            guard definition.kind.indicatesReferenceType else {
                switch definition.kind {
                case .struct, .enum:
                    // A confirmed value type keeps the reference-type gate closed.
                    return ExternalTypeFacts(isReferenceType: false)
                default:
                    // protocol / typealias / etc. — not a concrete reference type
                    // and not a value type; upgrade nothing.
                    return nil
                }
            }
            // Class/actor confirmed. Parse the declaring source (if readable) for
            // its outgoing strong edges; otherwise resolve class-ness only.
            return parseDeclaringType(named: name, file: definition.file)
                ?? ExternalTypeFacts(isReferenceType: true)
        }

        private func parseDeclaringType(named name: String, file: String) -> ExternalTypeFacts? {
            guard file.hasSuffix(".swift"),
                let data = try? BoundedFileReader.read(path: file, cap: Self.sourceByteCap),
                let source = String(data: data, encoding: .utf8)
            else { return nil }

            let facts = FactsExtraction.extract(path: file, source: source, defines: defines)
            guard let type = facts.types.first(where: { $0.name == name }) else { return nil }

            let isModel = type.attributeNames.contains("Model")
            var strongReferences: [ExternalStrongReference] = []
            var weakMembers: Set<String> = []
            for property in type.storedProperties {
                if property.strength == .weak { weakMembers.insert(property.name) }
                if property.strength == .strong, !isModel || property.hasTransientAttribute {
                    strongReferences.append(
                        ExternalStrongReference(
                            property: property.name,
                            referencedTypeNames: property.referencedTypeNames,
                            position: property.position
                        )
                    )
                }
            }
            return ExternalTypeFacts(
                isReferenceType: type.isReferenceType ?? true,
                weakMemberNames: weakMembers,
                inheritedTypeNames: type.inheritedTypeNames,
                strongReferences: strongReferences,
                declaringPath: file
            )
        }
    }
#endif
