#if canImport(IndexStoreDB)
    import Foundation
    import IndexStoreSupport
    import ProjectModel
    import SwiftParser

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

        /// Opens a resolver on the store `storePath` names, its database under `cacheRoot` (see
        /// ``IndexStoreReader/open(indexStorePath:cacheRoot:analyzedFiles:)``).
        public static func open(
            storePath: String, cacheRoot: String, analyzedFiles: [String], defines: Set<String> = []
        ) async throws(IndexStoreError) -> IndexStoreTypeResolver {
            // Symbolic links resolved, as the units record them.
            let resolved = analyzedFiles.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            let reader = try await IndexStoreReader.open(
                indexStorePath: storePath, cacheRoot: cacheRoot, analyzedFiles: resolved)
            return IndexStoreTypeResolver(reader: reader, defines: defines)
        }

        /// The store's root, canonical.
        public var storePath: String { reader.indexStorePath }

        /// Analyzed files the index has never seen, whose modification time is newer than the index's latest unit for
        /// them, or that cannot be read: the session's coverage (analyzerkit `IndexCoverage`) of the files it was
        /// opened with. A non-empty result means the store is stale relative to the corpus, and the caller goes
        /// corpus-only rather than resolve against a store that could be wrong.
        ///
        /// It is also the safety gate for stores of RELATIVE unit paths: absolute analyzed paths never match relative
        /// units, so such a store reports every file stale before any symbol query runs, which would abort an
        /// asserts build of libIndexStore.
        public var staleAnalyzedFiles: [String] {
            reader.session.coverage.files.filter { $0.coverage != .indexed }.map(\.path)
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
            // Class/actor confirmed. Parse the declaring source for its outgoing strong edges. Without Swift
            // source (an SDK type) the index's kind is all there is; a Swift source that no longer declares the
            // type means the record is out of date, and nothing is inferred from it.
            switch parseDeclaringType(named: name, file: definition.file) {
            case .declared(let facts): return facts
            case .gone: return nil
            case .noSwiftSource: return ExternalTypeFacts(isReferenceType: true)
            }
        }

        /// What the declaring file of an index definition says about the type now.
        private enum DeclaringSource {
            case declared(ExternalTypeFacts)
            /// The file is Swift source but cannot be read or no longer declares the type.
            case gone
            /// The definition is not in Swift source (an SDK or C header), so only the index can say.
            case noSwiftSource
        }

        private func parseDeclaringType(named name: String, file: String) -> DeclaringSource {
            guard file.hasSuffix(".swift") else { return .noSwiftSource }
            guard let data = try? BoundedFileReader.read(path: file, cap: Self.sourceByteCap),
                let source = String(data: data, encoding: .utf8)
            else { return .gone }

            let tree = Parser.parse(source: source)
            guard !SyntaxDepth.exceeds(tree) else { return .gone }
            let facts = FactsExtraction.extract(path: file, tree: tree, defines: defines)
            guard let type = facts.types.first(where: { $0.name == name }) else { return .gone }

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
            return .declared(
                ExternalTypeFacts(
                    isReferenceType: type.isReferenceType ?? true,
                    weakMemberNames: weakMembers,
                    inheritedTypeNames: type.inheritedTypeNames,
                    strongReferences: strongReferences,
                    declaringPath: file
                ))
        }
    }
#endif
