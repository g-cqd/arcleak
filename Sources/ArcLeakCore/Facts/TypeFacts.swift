/// Everything the rules need to know about one nominal type, merged across the
/// type's declaration and its same-file extensions.
public struct TypeFacts: Sendable, Codable {
    public let name: String
    /// `true` for class/actor declared in this file; `false` for struct/enum;
    /// `nil` when only an extension of an externally declared type was seen.
    /// Cycle rules gate on `== true` — unknown types are skipped, never guessed.
    public var isReferenceType: Bool?
    /// Stored properties, methods, and computed properties — used to resolve bare
    /// identifiers (`handler = …`, implicit members in Task bodies) to members.
    public var memberNames: Set<String>
    /// Superclass + conformance names (classes/actors) — powers lifetime
    /// heuristics (XCTestCase bodies, app-delegate/singleton owners).
    public var inheritedTypeNames: Set<String>
    /// Stored properties with their declared strength and referenced type names —
    /// the raw material of cross-file ownership-graph edges.
    public var storedProperties: [StoredPropertyFact]
    public var storedClosures: [StoredClosureFact]
    public var apiCalls: [APICallFact]
    public var taskSpawns: [TaskSpawnFact]
    public var releaseSites: [ReleaseSite]

    public init(name: String, isReferenceType: Bool?) {
        self.name = name
        self.isReferenceType = isReferenceType
        self.memberNames = []
        self.inheritedTypeNames = []
        self.storedProperties = []
        self.storedClosures = []
        self.apiCalls = []
        self.taskSpawns = []
        self.releaseSites = []
    }

    /// True when `kind` has a release call reachable outside `deinit`.
    public func hasReachableRelease(_ kind: ReleaseSite.Kind) -> Bool {
        releaseSites.contains { $0.kind == kind && !$0.inDeinit }
    }

    /// True when the only release calls for `kind` sit in `deinit`.
    public func releaseOnlyInDeinit(_ kind: ReleaseSite.Kind) -> Bool {
        let sites = releaseSites.filter { $0.kind == kind }
        return !sites.isEmpty && sites.allSatisfy(\.inDeinit)
    }
}
