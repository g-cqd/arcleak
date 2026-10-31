#if canImport(IndexStoreDB)
    public import Foundation
    import IndexStoreDB
    public import IndexStoreSupport
    import ProjectModel

    // MARK: - IndexStoreError

    /// Errors that can occur when opening or reading the index store. Every
    /// failure surface is collapsed here so callers never inspect Foundation /
    /// IndexStoreDB internals.
    public enum IndexStoreError: Error, Sendable, CustomStringConvertible {
        /// The path is not a store; `reason` says what to pass (analyzerkit `IndexStoreLocation`).
        case notAStore(reason: String)
        /// The library or the database could not be opened.
        case failedToOpen(reason: String)
        /// The store opened but indexes none of the `analyzedCount` analyzed files; `coverage` says how each was found.
        case coversNoAnalyzedFile(store: String, analyzedCount: Int, coverage: IndexCoverage)
        /// `libIndexStore.dylib` could not be located at any trusted path.
        case dylibNotFound

        public var description: String {
            switch self {
            case .notAStore(let reason): reason
            case .failedToOpen(let reason): reason
            case .coversNoAnalyzedFile(let store, let count, _):
                "index store at \(store) indexes none of \(count) analyzed file(s)"
            case .dylibNotFound: "no trusted libIndexStore.dylib was found"
            }
        }
    }

    // MARK: - IndexedSymbol

    /// Information about a symbol from the index store.
    public struct IndexedSymbol: Sendable {
        public let usr: String
        public let name: String
        public let kind: IndexedSymbolKind
        public let isSystem: Bool

        public init(usr: String, name: String, kind: IndexedSymbolKind, isSystem: Bool) {
            self.usr = usr
            self.name = name
            self.kind = kind
            self.isSystem = isSystem
        }
    }

    // MARK: - IndexedSymbolKind

    /// Kinds of symbols in the index store, projected from IndexStoreDB's
    /// `IndexSymbolKind`. (Swift `actor` declarations index with the `.class`
    /// kind, so `.class` covers both reference-type declarations.)
    public enum IndexedSymbolKind: String, Sendable {
        case `class`
        case `struct`
        case `enum`
        case `protocol`
        case `extension`
        case function
        case method
        case property
        case variable
        case parameter
        case `typealias`
        case module
        case unknown

        /// Bridge from IndexStoreDB's `IndexSymbolKind` (an internal import), so
        /// this is intentionally not `public`.
        init(from kind: IndexSymbolKind) {
            switch kind {
            case .class: self = .class
            case .struct: self = .struct
            case .enum: self = .enum
            case .protocol: self = .protocol
            case .extension: self = .extension
            case .classMethod, .function, .instanceMethod, .staticMethod:
                self = .function
            case .classProperty, .instanceProperty, .staticProperty:
                self = .property
            case .variable, .field:
                self = .variable
            case .parameter:
                self = .parameter
            case .typealias:
                self = .typealias
            case .module:
                self = .module
            default:
                self = .unknown
            }
        }

        /// Whether a declaration of this kind is an ARC reference type. Only
        /// `class` (which also covers `actor`) qualifies; struct/enum are value
        /// types and a bare `protocol` is not concrete, so both are `false`.
        public var indicatesReferenceType: Bool { self == .class }
    }

    // MARK: - IndexedOccurrence

    /// Where a symbol occurs in the codebase.
    public struct IndexedOccurrence: Sendable {
        public let symbol: IndexedSymbol
        public let file: String
        public let line: Int
        public let column: Int
        public let roles: IndexedSymbolRoles

        public init(
            symbol: IndexedSymbol,
            file: String,
            line: Int,
            column: Int,
            roles: IndexedSymbolRoles
        ) {
            self.symbol = symbol
            self.file = file
            self.line = line
            self.column = column
            self.roles = roles
        }
    }

    // MARK: - IndexedSymbolRoles

    /// Roles a symbol can have in an occurrence.
    public struct IndexedSymbolRoles: OptionSet, Sendable {
        public let rawValue: UInt64

        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }

        public static let declaration = Self(rawValue: 1 << 0)
        public static let definition = Self(rawValue: 1 << 1)
        public static let reference = Self(rawValue: 1 << 2)
        public static let read = Self(rawValue: 1 << 3)
        public static let write = Self(rawValue: 1 << 4)
        public static let call = Self(rawValue: 1 << 5)
        public static let dynamic = Self(rawValue: 1 << 6)
        public static let implicit = Self(rawValue: 1 << 7)

        /// Whether the occurrence represents a declaration site.
        public var isDefinitionLike: Bool {
            contains(.definition) || contains(.declaration)
        }

        /// Whether the occurrence represents an actual use-site.
        public var indicatesUsage: Bool {
            contains(.reference) || contains(.call) || contains(.read) || contains(.write)
        }
    }

    // MARK: - IndexStoreReader

    /// Reads symbol information from a Swift index store.
    ///
    /// `@unchecked Sendable` because IndexStoreDB is documented thread-safe for
    /// concurrent reads but is not itself `Sendable`. This type is read-only:
    /// `db` is set once in `init` and never mutated.
    public final class IndexStoreReader: @unchecked Sendable {
        /// The store's root, canonical.
        public let indexStorePath: String
        /// The session the reader queries: the store opened by analyzerkit (ADR-0004), its database under the cache
        /// root, and how it covered the analyzed files.
        public let session: IndexStoreSession

        /// The underlying IndexStoreDB database.
        private var db: IndexStoreDB { session.database }
        /// analyzerkit's queries over it (roadmap 0054): paths in the corpus's spelling.
        private let queries: IndexQueries

        public init(session: IndexStoreSession) {
            self.session = session
            indexStorePath = session.store
            queries = IndexQueries(session: session)
        }

        /// Opens the store `path` names (``IndexStoreLocation``), its database under `cacheRoot`, with the trusted
        /// `libIndexStore` that analyzerkit's toolchain resolution selects; a store that indexes none of
        /// `analyzedFiles` is refused before any query (ADR-0005).
        public static func open(
            indexStorePath path: String, cacheRoot: String, analyzedFiles: [String]
        ) async throws(IndexStoreError) -> IndexStoreReader {
            guard let library = await findLibIndexStore() else { throw .dylibNotFound }
            return try open(indexStorePath: path, cacheRoot: cacheRoot, library: library, analyzedFiles: analyzedFiles)
        }

        /// ``open(indexStorePath:cacheRoot:analyzedFiles:)`` with an explicit library, checked by the same trust policy
        /// before anything is opened.
        public static func open(
            indexStorePath path: String, cacheRoot: String, library: String, analyzedFiles: [String]
        ) throws(IndexStoreError) -> IndexStoreReader {
            switch IndexStoreSession.open(path, cacheRoot: cacheRoot, library: library, analyzedFiles: analyzedFiles) {
            case .usable(let session): return IndexStoreReader(session: session)
            case .notUsable(let store, let coverage):
                throw .coversNoAnalyzedFile(store: store, analyzedCount: analyzedFiles.count, coverage: coverage)
            case .notAStore(let reason): throw .notAStore(reason: reason)
            case .failed(let reason): throw .failedToOpen(reason: reason)
            }
        }

        // MARK: dylib discovery

        /// analyzerkit's ordered, audited resolution.
        public static func findLibIndexStore() async -> String? {
            await ToolchainResolution.resolve().libraryPath
        }

        // MARK: queries

        /// Every type definition the index records for `name` (class, actor, struct, enum, protocol, typealias), one per
        /// symbol and declaring file, sorted, so no caller depends on the order the index lists them in (A3).
        public func typeDefinitions(ofSymbolNamed name: String) -> [(
            usr: String, kind: IndexedSymbolKind, file: String
        )] {
            let typeKinds: Set<IndexedSymbolKind> = [.class, .struct, .enum, .protocol, .typealias]
            var seen: Set<String> = []
            var definitions: [(usr: String, kind: IndexedSymbolKind, file: String)] = []
            for occurrence in findOccurrences(ofSymbolNamed: name)
            where occurrence.roles.isDefinitionLike && typeKinds.contains(occurrence.symbol.kind)
                && seen.insert(occurrence.symbol.usr + "\u{0}" + occurrence.file).inserted
            {
                definitions.append((occurrence.symbol.usr, occurrence.symbol.kind, occurrence.file))
            }
            return definitions.sorted { ($0.usr, $0.file) < ($1.usr, $1.file) }
        }

        /// All canonical occurrences of a symbol with the given (anchored) name.
        public func findOccurrences(ofSymbolNamed name: String) -> [IndexedOccurrence] {
            queries.occurrences(named: name).map(Self.convert)
        }

        /// All occurrences of a symbol by USR.
        public func findOccurrences(ofUSR usr: String) -> [IndexedOccurrence] {
            queries.occurrences(ofUSR: usr).map(Self.convert)
        }

        /// Whether a symbol (by USR) has any reference occurrences.
        public func hasReferences(usr: String) -> Bool {
            queries.hasOccurrences(ofUSR: usr, roles: .reference)
        }

        /// Poll for changes to the index.
        public func pollForChanges() {
            db.pollForUnitChangesAndWait()
        }

        /// Date of the most recent index unit for `path`, or `nil` if the index
        /// has no unit for it (drives the staleness check).
        public func latestUnitDate(forFile path: String) -> Date? {
            db.dateOfLatestUnitFor(filePath: path)
        }

        private static func convert(_ occurrence: IndexQueries.Occurrence) -> IndexedOccurrence {
            IndexedOccurrence(
                symbol: IndexedSymbol(
                    usr: occurrence.usr,
                    name: occurrence.name,
                    kind: IndexedSymbolKind(from: occurrence.kind),
                    isSystem: false
                ),
                file: occurrence.file,
                line: occurrence.line,
                column: occurrence.column,
                roles: convert(occurrence.roles)
            )
        }

        private static func convert(_ roles: SymbolRole) -> IndexedSymbolRoles {
            var result = IndexedSymbolRoles()
            if roles.contains(.declaration) { result.insert(.declaration) }
            if roles.contains(.definition) { result.insert(.definition) }
            if roles.contains(.reference) { result.insert(.reference) }
            if roles.contains(.read) { result.insert(.read) }
            if roles.contains(.write) { result.insert(.write) }
            if roles.contains(.call) { result.insert(.call) }
            if roles.contains(.dynamic) { result.insert(.dynamic) }
            if roles.contains(.implicit) { result.insert(.implicit) }
            return result
        }
    }
#endif
