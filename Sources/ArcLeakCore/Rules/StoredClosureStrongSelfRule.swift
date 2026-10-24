import ProjectModel

/// `self.handler = { self.… }` — a closure stored on the instance capturing the
/// instance strongly is a guaranteed retain cycle (self → property → closure →
/// self). Gated on the enclosing type being a known reference type: struct
/// `self` is copied into the closure and cannot cycle.
///
/// One level down, `self.toolbar.onTap = { self.… }` (or `.append`) closes the
/// same loop through a child `self` owns: self → toolbar → onTap → self. The
/// child must be a strong stored property of this type, of any type: a struct
/// child is stored inline in `self` (extraction drops weak or unowned
/// children, locals and computed properties). Warning, not error: a child may
/// clear its callback after firing, which the source of `self` cannot show.
struct StoredClosureStrongSelfRule: Rule {
    static let emits: [RuleID] = [.storedClosureStrongSelf]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        return type.storedClosures.compactMap { stored in
            guard stored.selfCapture.isStrong else { return nil }
            if let child = stored.ownedChild {
                let member = stored.targetMember.dropFirst(child.count + 1)
                let value = stored.isMethodReference ? "bound method reference" : "closure"
                return Finding(
                    rule: .storedClosureStrongSelf,
                    severity: min(configuration.severity(for: .storedClosureStrongSelf), .warning),
                    path: path,
                    line: stored.position.line,
                    column: stored.position.column,
                    message:
                        "\(value) stored in '\(stored.targetMember)' captures self strongly — retain cycle through an owned child: self → \(child) → \(member) → self",
                    note:
                        "self keeps '\(child)' in a strong stored property and '\(child)' keeps the closure; capture [weak self], or clear '\(stored.targetMember)' when it is done"
                )
            }
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
