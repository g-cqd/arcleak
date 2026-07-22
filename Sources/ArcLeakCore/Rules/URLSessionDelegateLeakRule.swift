/// `URLSession(configuration:delegate: self, …)` — the docs mandate this rule
/// verbatim: "The session object keeps a strong reference to the delegate
/// until your app exits or explicitly invalidates the session. If you do not
/// invalidate the session … your app leaks memory until it exits."
///
/// Reachable invalidation (`invalidateAndCancel` / `finishTasksAndInvalidate`
/// outside `deinit`) means a managed lifecycle — silent. Deinit-only
/// invalidation is unreachable while the session holds `self` — error.
struct URLSessionDelegateLeakRule: Rule {
    static let emits: [RuleID] = [.urlSessionDelegateLeak]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.sessionInvalidate) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.sessionInvalidate)

        return type.apiCalls.compactMap { call in
            guard call.kind == .urlSessionWithDelegate, call.targetIsSelf else { return nil }

            let severity: Severity
            let note: String
            if deinitOnly {
                severity = .error
                note = "session invalidation only appears in deinit — the session's strong hold on its delegate (self) means deinit never runs; invalidate from a reachable path"
            } else {
                severity = configuration.severity(for: .urlSessionDelegateLeak)
                note = "docs: \"your app leaks memory until it exits\" without invalidateAndCancel()/finishTasksAndInvalidate(); none found in this type"
            }
            return Finding(
                rule: .urlSessionDelegateLeak,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message: "leak: URLSession keeps a strong reference to its delegate (self) until the session is explicitly invalidated",
                note: note
            )
        }
    }
}
