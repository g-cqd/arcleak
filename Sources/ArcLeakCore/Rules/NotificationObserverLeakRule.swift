/// Block-based `addObserver(forName:object:queue:using:)` with a strong `self`
/// capture. Per Foundation docs the center "strongly holds the copied block
/// until you remove the observer registration" — so the center anchors `self`.
/// Removal that only exists in `deinit` is unreachable by construction.
///
/// The selector-based `addObserver(_:selector:…)` variant does **not** retain
/// the observer and is deliberately not matched.
struct NotificationObserverLeakRule: Rule {
    static let emits: [RuleID] = [.notificationObserverLeak]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.removeObserver) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.removeObserver)

        return type.apiCalls.compactMap { call in
            guard call.kind == .notificationAddObserverBlock,
                call.closureSelfCapture?.isStrong == true
            else { return nil }

            let severity: Severity
            let note: String
            if deinitOnly {
                severity = .error
                note =
                    "removeObserver only appears in deinit — the center's strong hold on the block (which holds self) means deinit never runs; remove from a reachable path or capture [weak self]"
            } else {
                severity = configuration.severity(for: .notificationObserverLeak)
                note =
                    "NotificationCenter → block → self keeps self alive until removeObserver; capture [weak self] or remove the observer from a reachable path"
            }
            return Finding(
                rule: .notificationObserverLeak,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "leak: block observer captures self strongly and the notification center strongly holds the block until removal",
                note: note
            )
        }
    }
}
