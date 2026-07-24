#if canImport(IndexStoreDB)
    public import Foundation
    import IndexStoreDB

    // MARK: - IndexStoreError

    /// Errors that can occur when opening or reading the index store. Every
    /// failure surface is collapsed here so callers never inspect Foundation /
    /// IndexStoreDB internals.
    public enum IndexStoreError: Error, Sendable {
        case indexStoreNotFound(path: String)
        case failedToOpenDatabase(underlying: String)
        case databaseDirectoryMissing(String)
        /// `libIndexStore.dylib` could not be located at any trusted path.
        case dylibNotFound
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
        /// The path to the index store.
        public let indexStorePath: String

        /// The underlying IndexStoreDB database.
        private let db: IndexStoreDB

        /// Open a reader, resolving `libIndexStore.dylib` synchronously from the
        /// static/user toolchain candidate paths. Use ``open(indexStorePath:allowsDirectoryCreation:)``
        /// for the async path that additionally consults `xcrun`.
        public init(
            indexStorePath: String,
            libIndexStorePath: String? = nil,
            allowsDirectoryCreation: Bool = true
        ) throws(IndexStoreError) {
            self.indexStorePath = indexStorePath

            let libPath: String
            if let provided = libIndexStorePath {
                libPath = provided
            } else if let resolved = Self.resolveLibraryPathSync() {
                libPath = resolved
            } else {
                throw IndexStoreError.dylibNotFound
            }

            // libIndexStore aborts on a relative store path
            // ("passed relative path without working-dir"), so absolutize it
            // against the current directory before handing it over — a relative
            // `--index-store-path` must degrade gracefully, never crash.
            let absolute =
                (indexStorePath as NSString).isAbsolutePath
                ? indexStorePath
                : FileManager.default.currentDirectoryPath + "/" + indexStorePath
            let storePath = URL(fileURLWithPath: absolute).standardizedFileURL
            let databasePath = storePath.deletingLastPathComponent()
                .appendingPathComponent("IndexDatabase")

            if allowsDirectoryCreation {
                do {
                    try FileManager.default.createDirectory(
                        at: databasePath, withIntermediateDirectories: true
                    )
                } catch {
                    throw IndexStoreError.failedToOpenDatabase(underlying: error.localizedDescription)
                }
            } else {
                var isDirectory: ObjCBool = false
                // `isDirectory:` is an ObjCBool out-parameter; the inout pointer
                // is explicitly `unsafe` under strict memory safety.
                let exists = unsafe FileManager.default.fileExists(
                    atPath: databasePath.path, isDirectory: &isDirectory
                )
                if !exists || !isDirectory.boolValue {
                    throw IndexStoreError.databaseDirectoryMissing(databasePath.path)
                }
            }

            do {
                db = try IndexStoreDB(
                    storePath: storePath.path,
                    databasePath: databasePath.path,
                    library: IndexStoreLibrary(dylibPath: libPath),
                    waitUntilDoneInitializing: true
                )
            } catch {
                throw IndexStoreError.failedToOpenDatabase(underlying: error.localizedDescription)
            }
        }

        /// Async factory: resolves the dylib via the full candidate list
        /// (including an `xcrun --find swift` fallback) and opens the reader.
        public static func open(
            indexStorePath: String,
            allowsDirectoryCreation: Bool = true
        ) async throws(IndexStoreError) -> IndexStoreReader {
            guard let lib = await findLibIndexStore() else {
                throw IndexStoreError.dylibNotFound
            }
            return try IndexStoreReader(
                indexStorePath: indexStorePath,
                libIndexStorePath: lib,
                allowsDirectoryCreation: allowsDirectoryCreation
            )
        }

        // MARK: dylib discovery

        /// Synchronous candidate paths (no subprocess): system toolchains and
        /// the user's `~/Library/Developer/Toolchains` snapshots.
        static func resolveLibraryPathSync() -> String? {
            for candidate in staticCandidatePaths() where isTrustedDylib(at: candidate) {
                return candidate
            }
            return nil
        }

        /// Full async resolution. `xcrun --find swift` is consulted first so the
        /// dylib reflects the toolchain that `swift build` resolves to on `PATH`
        /// (which is also what the auto-build path invokes), then the static and
        /// user-toolchain candidates.
        public static func findLibIndexStore() async -> String? {
            if let fromXcrun = await xcrunDerivedDylib(), isTrustedDylib(at: fromXcrun) {
                return fromXcrun
            }
            return resolveLibraryPathSync()
        }

        private static func xcrunDerivedDylib() async -> String? {
            guard
                let result = try? await ProcessExecutor.run(
                    executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: ["--find", "swift"]
                ),
                result.succeeded
            else { return nil }
            let swiftPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !swiftPath.isEmpty else { return nil }
            return URL(fileURLWithPath: swiftPath)
                .deletingLastPathComponent()  // bin
                .deletingLastPathComponent()  // usr
                .appendingPathComponent("lib")
                .appendingPathComponent("libIndexStore.dylib")
                .path
        }

        private static func staticCandidatePaths() -> [String] {
            var paths = [
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
                "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/lib/libIndexStore.dylib",
                "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib",
            ]
            // User-installed toolchains (swiftly snapshots, downloaded
            // toolchains) live here and are user-owned — the common case for a
            // dev CLI. Newest snapshot first.
            let userToolchains = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Developer/Toolchains")
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: userToolchains.path) {
                for entry in entries.sorted(by: >) where entry.hasSuffix(".xctoolchain") {
                    paths.append(
                        userToolchains.appendingPathComponent(entry)
                            .appendingPathComponent("usr/lib/libIndexStore.dylib").path
                    )
                }
            }
            return paths
        }

        /// A candidate is trusted after symlink resolution (so `swift-latest` is
        /// followed to its real target before the ownership/permission check).
        private static func isTrustedDylib(at path: String) -> Bool {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return BinaryTrustChecker.isTrusted(at: resolved)
        }

        // MARK: queries

        /// Definition kind + declaring file for the first canonical definition
        /// occurrence of `name`, or `nil` when the index doesn't know it.
        public func definition(ofSymbolNamed name: String) -> (kind: IndexedSymbolKind, file: String)? {
            for occurrence in findOccurrences(ofSymbolNamed: name) where occurrence.roles.isDefinitionLike {
                return (occurrence.symbol.kind, occurrence.file)
            }
            return nil
        }

        /// All canonical occurrences of a symbol with the given (anchored) name.
        public func findOccurrences(ofSymbolNamed name: String) -> [IndexedOccurrence] {
            var occurrences: [IndexedOccurrence] = []
            db.forEachCanonicalSymbolOccurrence(
                containing: name,
                anchorStart: true,
                anchorEnd: true,
                subsequence: false,
                ignoreCase: false
            ) { occurrence in
                occurrences.append(Self.convert(occurrence))
                return true
            }
            return occurrences
        }

        /// All occurrences of a symbol by USR.
        public func findOccurrences(ofUSR usr: String) -> [IndexedOccurrence] {
            var occurrences: [IndexedOccurrence] = []
            db.forEachSymbolOccurrence(byUSR: usr, roles: .all) { occurrence in
                occurrences.append(Self.convert(occurrence))
                return true
            }
            return occurrences
        }

        /// Whether a symbol (by USR) has any reference occurrences.
        public func hasReferences(usr: String) -> Bool {
            var hasRef = false
            db.forEachSymbolOccurrence(byUSR: usr, roles: .reference) { _ in
                hasRef = true
                return false
            }
            return hasRef
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

        private static func convert(_ occurrence: SymbolOccurrence) -> IndexedOccurrence {
            IndexedOccurrence(
                symbol: IndexedSymbol(
                    usr: occurrence.symbol.usr,
                    name: occurrence.symbol.name,
                    kind: IndexedSymbolKind(from: occurrence.symbol.kind),
                    isSystem: false
                ),
                file: occurrence.location.path,
                line: occurrence.location.line,
                column: occurrence.location.utf8Column,
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

    // MARK: - IndexStorePathFinder

    /// Finds an index-store directory in a project (SwiftPM `.build`, then Xcode
    /// DerivedData). An explicit `--index-store-path` always wins upstream; this
    /// is the probe used when none is given.
    public struct IndexStorePathFinder: Sendable {
        public static func findIndexStorePath(in projectRoot: String) -> String? {
            let buildDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".build")
            // Only stores that record ABSOLUTE source paths are safe to query:
            // SourceKit-LSP's background index (`.build/index-build`), the classic
            // SwiftPM index (`.build/<config>/index/store`), arcleak's own
            // auto-build target (`.build/index/store`), and Xcode DerivedData all
            // qualify. The current Swift Build system's `.build/out` store records
            // RELATIVE unit paths, which abort an asserts build of libIndexStore
            // on query — it is deliberately NOT discovered. Only a POPULATED store
            // counts, so an empty override target loses to a populated sibling.
            let candidates = [
                buildDir.appendingPathComponent("index-build/index/store"),
                buildDir.appendingPathComponent("debug/index/store"),
                buildDir.appendingPathComponent("release/index/store"),
                buildDir.appendingPathComponent("index/store"),
            ]
            for candidate in candidates where isPopulatedStore(candidate) {
                return candidate.path
            }
            return findDerivedDataStore(projectRoot: projectRoot)
        }

        private static func findDerivedDataStore(projectRoot: String) -> String? {
            let derivedData = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Developer/Xcode/DerivedData")
            guard
                let contents = try? FileManager.default.contentsOfDirectory(atPath: derivedData.path)
            else { return nil }

            let projectName = URL(fileURLWithPath: projectRoot).lastPathComponent
            let normalized = normalizeProjectName(projectName)
            for dir in contents.sorted()
            where dirMatchesProject(dir, projectName: projectName, normalizedName: normalized) {
                let dataStore =
                    derivedData
                    .appendingPathComponent(dir)
                    .appendingPathComponent("Index.noindex")
                    .appendingPathComponent("DataStore")
                // libIndexStore is handed the store ROOT (the `-index-store-path`
                // / `INDEX_DATA_STORE_DIR` value); it navigates the internal `vN`
                // layout itself. Returning the versioned subdir instead makes
                // per-file unit lookups miss (empirically a false-stale).
                if isPopulatedStore(dataStore) {
                    return dataStore.path
                }
            }
            return nil
        }

        /// A store is usable only if it actually holds index records — directly,
        /// or under its newest `vN` subdir. An empty `vN/units` (a build that
        /// emitted nothing to this path) does not count, so a populated sibling
        /// store wins discovery.
        private static func isPopulatedStore(_ url: URL) -> Bool {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                return false
            }
            if hasRecords(in: url) { return true }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                return false
            }
            for entry in entries where entry.hasPrefix("v") && entry.dropFirst().allSatisfy(\.isNumber) {
                if hasRecords(in: url.appendingPathComponent(entry)) { return true }
            }
            return false
        }

        /// Whether `url/records` exists and is non-empty.
        private static func hasRecords(in url: URL) -> Bool {
            let records = url.appendingPathComponent("records")
            let entries = try? FileManager.default.contentsOfDirectory(atPath: records.path)
            return !(entries ?? []).isEmpty
        }

        private static func normalizeProjectName(_ name: String) -> String {
            let toReplace = CharacterSet(charactersIn: " -.")
            var normalized = name
            for scalar in name.unicodeScalars where toReplace.contains(scalar) {
                normalized = normalized.replacingOccurrences(of: String(scalar), with: "_")
            }
            return normalized
        }

        private static func dirMatchesProject(
            _ dir: String, projectName: String, normalizedName: String
        ) -> Bool {
            let components = dir.split(separator: "-", maxSplits: 1)
            guard let first = components.first else { return false }
            let name = String(first)
            if name == projectName || name == normalizedName { return true }
            if let decoded = name.removingPercentEncoding, decoded == projectName { return true }
            return dir.contains(projectName) || dir.contains(normalizedName)
        }
    }
#endif
