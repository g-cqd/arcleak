/// The opt-in security pack: rules that read the findings already reported
/// for a type rather than its facts alone. Each is disabled by default and
/// enabled through `rules.<id>.enabled` in `.arcleak.json`.
///
/// `sec-cleanup-in-unreachable-deinit` (CWE-401, CWE-226): the type's deinit
/// wipes bytes, invalidates, closes, cancels or removes something, and a
/// finding reported on the same type may keep it alive, so that cleanup may
/// never run. "May": `keepsSelfAlive` includes warnings, which are not all
/// proven cycles (a source may complete, a teardown may run).
///
/// `sec-session-in-cycle` (CWE-401): a tag, not a finding of its own. When the
/// type holds a web view, an authentication context or session, or a URL
/// session with a delegate, each cycle finding on it gets a note saying what
/// the cycle keeps alive.
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
        if configuration.isEnabled(.secSessionInCycle) {
            let held = sensitiveHeld(by: type)
            if !held.isEmpty {
                let tag =
                    "security (sec-session-in-cycle, CWE-401): this cycle keeps \(held.joined(separator: ", ")) alive with '\(type.name)' — authenticated state outlives the object that owns it"
                result = result.map { keepsSelfAlive.contains($0.rule) ? $0.adding(note: tag) : $0 }
            }
        }
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
                "security: deinit of '\(type.name)' \(actions.joined(separator: ", ")), but the \(cycle.rule.rawValue) finding here may keep '\(type.name)' alive, so that cleanup may never run",
            note:
                "CWE-401/CWE-226: break the cycle, and move cleanup that must happen (wiping secrets, invalidating sessions, closing handles) to a reachable teardown path"
        )
    }

    /// Sensitive objects the type keeps, by declared type name (SDK types are
    /// matched by name: no index is needed). A URL session counts only when
    /// the type creates one with a delegate; a web view also counts when the
    /// type registers a script message handler.
    private static func sensitiveHeld(by type: TypeFacts) -> [String] {
        let declared = Set(
            type.storedProperties.filter { $0.strength == .strong }.flatMap(\.referencedTypeNames)
        )
        var held: [String] = []
        if declared.contains("WKWebView") || type.apiCalls.contains(where: { $0.kind == .scriptMessageHandlerAdd }) {
            held.append("a WKWebView")
        }
        if declared.contains("LAContext") {
            held.append("an LAContext")
        }
        if declared.contains("ASWebAuthenticationSession") {
            held.append("an ASWebAuthenticationSession")
        }
        if type.apiCalls.contains(where: { $0.kind == .urlSessionWithDelegate }) {
            held.append("a URLSession with a delegate")
        }
        return held
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
