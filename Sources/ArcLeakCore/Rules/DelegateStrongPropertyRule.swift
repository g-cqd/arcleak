/// Opt-in (name heuristic until the index layer provides class-bound protocol
/// facts): a strong stored property that reads as a delegate/data source is
/// the classic back-reference that closes owner ↔ observer cycles.
struct DelegateStrongPropertyRule: Rule {
    static let emits: [RuleID] = [.delegateStrongProperty]

    private static let suffixes = ["delegate", "datasource"]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        return type.storedProperties.compactMap { property in
            guard property.strength == .strong, looksLikeDelegate(property) else { return nil }
            return Finding(
                rule: .delegateStrongProperty,
                severity: configuration.severity(for: .delegateStrongProperty),
                path: path,
                line: property.position.line,
                column: property.position.column,
                message:
                    "strong stored property '\(property.name)' looks like a delegate — back-references close cycles when both sides are strong",
                note:
                    "declare it `weak var` unless this object provably owns its delegate (TSPL: weak for shorter-lived referents)"
            )
        }
    }

    private static func looksLikeDelegate(_ property: StoredPropertyFact) -> Bool {
        let name = property.name.lowercased()
        if suffixes.contains(where: name.hasSuffix) { return true }
        return property.referencedTypeNames.contains { typeName in
            let lowered = typeName.lowercased()
            return suffixes.contains(where: lowered.hasSuffix)
        }
    }
}
