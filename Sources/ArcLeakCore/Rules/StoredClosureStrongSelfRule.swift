/// `self.handler = { self.… }` — a closure stored on the instance capturing the
/// instance strongly is a guaranteed retain cycle (self → property → closure →
/// self). Gated on the enclosing type being a known reference type: struct
/// `self` is copied into the closure and cannot cycle.
struct StoredClosureStrongSelfRule: Rule {
    static let emits: [RuleID] = [.storedClosureStrongSelf]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        return type.storedClosures.compactMap { stored in
            guard stored.selfCapture.isStrong else { return nil }
            if stored.isMethodReference {
                return Finding(
                    rule: .storedClosureStrongSelf,
                    severity: configuration.severity(for: .storedClosureStrongSelf),
                    path: path,
                    line: stored.position.line,
                    column: stored.position.column,
                    message:
                        "bound method reference stored in '\(stored.targetMember)' captures self strongly — retain cycle: self → \(stored.targetMember) → self",
                    note:
                        "method references have no capture-list syntax; wrap in a closure: { [weak self] in self?.method($0) }"
                )
            }
            return Finding(
                rule: .storedClosureStrongSelf,
                severity: configuration.severity(for: .storedClosureStrongSelf),
                path: path,
                line: stored.position.line,
                column: stored.position.column,
                message:
                    "closure stored in '\(stored.targetMember)' captures self strongly — retain cycle: self → \(stored.targetMember) → self",
                note:
                    "capture with [weak self] and unwrap, or [unowned self] only if the closure can never outlive self (Swift book: same-lifetime rule)"
            )
        }
    }
}
