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

/// Index-resolved facts about an externally declared type.
public struct ExternalTypeFacts: Sendable, Codable, Equatable {
    public var isReferenceType: Bool
    /// Members declared `weak` — powers delegate-rule upgrades.
    public var weakMemberNames: Set<String>
    public var inheritedTypeNames: Set<String>

    public init(
        isReferenceType: Bool,
        weakMemberNames: Set<String> = [],
        inheritedTypeNames: Set<String> = []
    ) {
        self.isReferenceType = isReferenceType
        self.weakMemberNames = weakMemberNames
        self.inheritedTypeNames = inheritedTypeNames
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
