/// The opt-in security pack: rules that read the findings already reported
/// for a type rather than its facts alone. Each is disabled by default and
/// enabled through `rules.<id>.enabled` in `.arcleak.json`.
///
/// `sec-cleanup-in-unreachable-deinit` (CWE-401, CWE-226): the type's deinit
/// wipes bytes, invalidates, closes, cancels or removes something, and a cycle
/// reported on the same type keeps it alive, so that cleanup never runs.
enum SecurityPack {
    /// Findings meaning "this instance can never deinit": a cycle through
    /// `self`, or an anchor (run loop, notification center, session, user
    /// content controller) that holds `self` until a release deinit cannot
    /// reach.
    static let keepsSelfAlive: Set<RuleID> = [
        .storedClosureStrongSelf, .combineSinkSelfCycle, .combineAssignSelfCycle, .dispatchSourceCycle,
        .taskNonterminatingSelf, .timerRetainsSelf, .notificationObserverLeak, .urlSessionDelegateLeak,
        .webviewScriptHandlerCycle, .kvoObservationSelfCycle,
    ]

    /// `findings` (one type's, already filtered by configuration) plus the
    /// enabled security findings derived from them.
    static func apply(
        to findings: [Finding],
        type: TypeFacts,
        path: String,
        configuration: Configuration
    ) -> [Finding] {
        guard let cycle = findings.filter({ keepsSelfAlive.contains($0.rule) }).min() else { return findings }
        var result = findings
        if configuration.isEnabled(.secCleanupInUnreachableDeinit),
            let cleanup = unreachableCleanup(type: type, cycle: cycle, path: path, configuration: configuration)
        {
            result.append(cleanup)
        }
        return result
    }

    private static func unreachableCleanup(
        type: TypeFacts,
        cycle: Finding,
        path: String,
        configuration: Configuration
    ) -> Finding? {
        let kinds = Set(type.releaseSites.filter(\.inDeinit).map(\.kind))
        let actions = cleanupDescriptions.compactMap { kinds.contains($0.kind) ? $0.text : nil }
        guard !actions.isEmpty else { return nil }
        return Finding(
            rule: .secCleanupInUnreachableDeinit,
            severity: configuration.severity(for: .secCleanupInUnreachableDeinit),
            path: path,
            line: cycle.line,
            column: cycle.column,
            message:
                "security: deinit of '\(type.name)' \(actions.joined(separator: ", ")), but the \(cycle.rule.rawValue) finding here keeps '\(type.name)' alive, so that cleanup never runs",
            note:
                "CWE-401/CWE-226: break the cycle, and move cleanup that must happen (wiping secrets, invalidating sessions, closing handles) to a reachable teardown path"
        )
    }

    /// In report order.
    private static let cleanupDescriptions: [(kind: ReleaseSite.Kind, text: String)] = [
        (.zeroBytes, "wipes memory"),
        (.sessionInvalidate, "invalidates a URL session"),
        (.invalidate, "invalidates a timer or observation"),
        (.close, "closes a handle"),
        (.cancel, "cancels work"),
        (.removeObserver, "removes an observer"),
        (.removeScriptMessageHandler, "removes a script message handler"),
    ]
}
