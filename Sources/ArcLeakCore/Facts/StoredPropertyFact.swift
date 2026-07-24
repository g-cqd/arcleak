public import ADJSON

/// One stored property of a type: the raw material of ownership-graph edges.
///
/// `referencedTypeNames` are the nominal type names appearing in the declared
/// type (unwrapping optionals, arrays, dictionary values, generic arguments) or
/// inferred from a direct `= TypeName(...)` initializer. Resolution against the
/// analyzed corpus happens at graph-build time; names that don't resolve to a
/// known class/actor simply produce no edge.
@JSONCodable
public struct StoredPropertyFact: Sendable, Equatable, Codable {
    public let name: String
    public let strength: ReferenceStrength
    public let referencedTypeNames: [String]
    /// `@Published` — the projected publisher never completes while the object
    /// lives; feeds upstream-finiteness resolution.
    public let hasPublishedAttribute: Bool
    /// `@Transient` — on a SwiftData `@Model` type this is REAL ARC storage
    /// (the macro manages everything else), so it still forms ownership edges.
    public let hasTransientAttribute: Bool
    public let position: SourcePosition

    public init(
        name: String,
        strength: ReferenceStrength,
        referencedTypeNames: [String],
        hasPublishedAttribute: Bool = false,
        hasTransientAttribute: Bool = false,
        position: SourcePosition
    ) {
        self.name = name
        self.strength = strength
        self.referencedTypeNames = referencedTypeNames
        self.hasPublishedAttribute = hasPublishedAttribute
        self.hasTransientAttribute = hasTransientAttribute
        self.position = position
    }
}
