/// The whole-program index seam. L1–L3 never depend on an index; when one is
/// available it *adds* resolved facts about externally declared types through
/// this protocol, and every consumer degrades to silence — never guessing —
/// when it is absent or stale.
///
/// The real backend (indexstore-db, revision-pinned) lands when the 6.4
/// toolchain GAs, per the recorded decision in DESIGN.md. Until then the seam
/// is exercised by fake indexes in tests, so consumer code is proven before
/// the backend exists.
public protocol IndexReading: Sendable {
    /// Facts for a type not declared in the analyzed corpus, or nil if the
    /// index doesn't know it either.
    func externalTypeFacts(name: String) -> ExternalTypeFacts?
}

/// One strong stored-property reference of an externally declared type: the
/// raw material of a cross-module ownership-graph edge. Populated only when the
/// external type's declaring source could be located (via the index) and
/// parsed — an SDK type with no readable source resolves to class-ness only,
/// with no edges.
public struct ExternalStrongReference: Sendable, Codable, Equatable {
    public var property: String
    public var referencedTypeNames: [String]
    public var position: SourcePosition

    public init(property: String, referencedTypeNames: [String], position: SourcePosition) {
        self.property = property
        self.referencedTypeNames = referencedTypeNames
        self.position = position
    }
}

/// Index-resolved facts about an externally declared type.
public struct ExternalTypeFacts: Sendable, Codable, Equatable {
    public var isReferenceType: Bool
    /// Members declared `weak` — powers delegate-rule upgrades.
    public var weakMemberNames: Set<String>
    public var inheritedTypeNames: Set<String>
    /// The external type's own strong stored-property references. When this type
    /// is pulled into the ownership graph as an external node, these become its
    /// outgoing edges — the mechanism that lets a strong property pointing at a
    /// class in another module *complete* a cross-module cycle.
    public var strongReferences: [ExternalStrongReference]
    /// The file that declares this type, if the index located a parseable
    /// source for it — used as the provenance path of external-node edges.
    public var declaringPath: String?

    public init(
        isReferenceType: Bool,
        weakMemberNames: Set<String> = [],
        inheritedTypeNames: Set<String> = [],
        strongReferences: [ExternalStrongReference] = [],
        declaringPath: String? = nil
    ) {
        self.isReferenceType = isReferenceType
        self.weakMemberNames = weakMemberNames
        self.inheritedTypeNames = inheritedTypeNames
        self.strongReferences = strongReferences
        self.declaringPath = declaringPath
    }
}

extension FileFacts {
    /// Upgrades extension-of-external-type entries (`isReferenceType == nil`)
    /// with index knowledge, unlocking the reference-type-gated rules for
    /// bodies declared in extensions of imported classes.
    public func upgraded(with index: any IndexReading) -> FileFacts {
        var upgraded = self
        upgraded.types = types.map { type in
            guard type.isReferenceType == nil,
                let external = index.externalTypeFacts(name: type.name)
            else { return type }
            var merged = type
            merged.isReferenceType = external.isReferenceType
            merged.inheritedTypeNames.formUnion(external.inheritedTypeNames)
            return merged
        }
        return upgraded
    }
}
