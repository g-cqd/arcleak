#if canImport(IndexStoreDB)
    import Foundation
    public import IndexStoreSupport
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

        /// How the store covered the analyzed files when it was opened (analyzerkit `IndexCoverage`).
        public var coverage: IndexCoverage { reader.session.coverage }

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

        /// What the index says of a type the corpus does not declare, decided per definition (ADR-0005 item 3):
        /// - every type definition of the name counts; when they disagree (a struct in one module, a class in another)
        ///   nothing is answered (A3);
        /// - a definition whose declaring Swift file changed since the build, or was never built, is not used (A4); an SDK
        ///   header is the index's word alone;
        /// - a class is read from its declaring file now, and a file that no longer declares it answers nothing; several
        ///   classes of one name answer that it is a class, with no edges, since which one is meant is not known.
        private func resolve(name: String) -> ExternalTypeFacts? {
            let definitions = reader.typeDefinitions(ofSymbolNamed: name)
            guard !definitions.isEmpty else { return nil }  // the index doesn't know this name — degrade to silence
            let freshness = reader.session.freshness
            for definition in definitions where definition.file.hasSuffix(".swift") {
                guard freshness.isCurrent(definition.file) else { return nil }
            }
            let kinds = Set(definitions.map(\.kind))
            if kinds.allSatisfy({ $0 == .struct || $0 == .enum }) {
                return ExternalTypeFacts(isReferenceType: false)  // a confirmed value type keeps the gate closed
            }
            // A protocol or typealias is neither; a mix of kinds is a disagreement.
            guard kinds == [.class] else { return nil }
            guard Set(definitions.map(\.usr)).count == 1, Set(definitions.map(\.file)).count == 1,
                let definition = definitions.first
            else { return ExternalTypeFacts(isReferenceType: true) }
            // Parse the declaring source for its outgoing strong edges. Without Swift source (an SDK type) the index's
            // kind is all there is; a Swift source that no longer declares the type means the record is out of date.
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
