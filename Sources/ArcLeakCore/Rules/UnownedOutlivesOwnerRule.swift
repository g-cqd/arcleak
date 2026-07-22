/// `[unowned self]` in a closure held by an external anchor (repeating timer,
/// NotificationCenter block observer, periodic time observer, dispatch-source
/// handler). The Swift book licenses `unowned` only for same-or-longer referent
/// lifetimes; an anchor-held closure outlives arbitrary objects, so the first
/// callback after `self` deallocates traps deterministically.
///
/// The book-blessed shape — `[unowned self]` on a closure stored on `self`
/// itself — is deliberately NOT matched (that one is same-lifetime by
/// construction and is the documented correct pattern).
struct UnownedOutlivesOwnerRule: Rule {
    static let emits: [RuleID] = [.unownedOutlivesOwner]

    private static let anchoredKinds: Set<APICallFact.Kind> = [
        .timerScheduledBlock,
        .notificationAddObserverBlock,
        .periodicTimeObserver,
        .dispatchSourceHandler,
    ]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        return type.apiCalls.compactMap { call in
            guard anchoredKinds.contains(call.kind), call.closureSelfCapture == .unowned else {
                return nil
            }
            return Finding(
                rule: .unownedOutlivesOwner,
                severity: configuration.severity(for: .unownedOutlivesOwner),
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "crash risk: [unowned self] in a closure held by an external anchor — if self deallocates before the closure is released, the next access traps",
                note:
                    "use [weak self] here; unowned is only safe when the closure can never outlive self (Swift book: same-or-longer lifetime rule)"
            )
        }
    }
}
