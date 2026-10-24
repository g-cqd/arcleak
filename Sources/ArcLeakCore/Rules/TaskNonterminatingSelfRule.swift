import ProjectModel

/// `Task { while true { … } }` / `Task { for await … }` capturing `self`
/// strongly. A task retains its captures until it completes; a task that never
/// completes keeps `self` alive forever. If `self` also stores the handle, the
/// only exit is `cancel()` — and `cancel()` in `deinit` is unreachable inside
/// the cycle.
///
/// `Task.init` is `@_implicitSelfCapture`, so bare member access captures
/// `self` with no `self` token in source — the compiler's explicit-self guard
/// is deliberately absent here, which is exactly why this rule exists.
/// Finite tasks capturing `self` are lifetime extension, not leaks; they are
/// not flagged — except one shape: a task whose body awaits, whose handle is
/// stored on `self`, and whose only `cancel()` sits in `deinit`. That cancel
/// cannot run while the task holds `self`, so `self` lives as long as the
/// awaited work, forever if it never returns (the timer rule's deinit-only
/// idiom). Not definite, so it reports at the configured severity.
struct TaskNonterminatingSelfRule: Rule {
    static let emits: [RuleID] = [.taskNonterminatingSelf]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        // A cancel() reachable outside deinit means a managed lifecycle
        // (viewWillDisappear/stop()) — the same silence contract as the timer,
        // observer, and dispatch-source rules. Deinit-only cancel stays a
        // finding: deinit is unreachable while the task retains self.
        guard !type.hasReachableRelease(.cancel) else { return [] }
        let cancelOnlyInDeinit = type.releaseOnlyInDeinit(.cancel)
        return type.taskSpawns.compactMap { spawn in
            guard spawn.selfCapture.isStrong else { return nil }
            guard spawn.hasNonterminatingBody else {
                guard cancelOnlyInDeinit, spawn.bodyAwaits, spawn.consumption.storesIntoSelf else { return nil }
                return Finding(
                    rule: .taskNonterminatingSelf,
                    severity: configuration.severity(for: .taskNonterminatingSelf),
                    path: path,
                    line: spawn.position.line,
                    column: spawn.position.column,
                    message:
                        "Task stored on self captures self strongly and is cancelled only in deinit — self lives until every await in the task returns",
                    note:
                        "deinit cannot run while the task holds self, so its cancel() never fires; if an await never returns, self leaks — capture [weak self] or cancel from a reachable path (viewDidDisappear/stop())"
                )
            }

            let implicitly: String
            if case .strong(implicit: true) = spawn.selfCapture {
                implicitly = " implicitly (Task bodies capture self without writing it)"
            } else {
                implicitly = ""
            }

            let severity: Severity
            let note: String
            if spawn.consumption.storesIntoSelf {
                severity = .error
                note =
                    "self stores the task handle while the task retains self — cancel() in deinit can never run; capture [weak self] (exit when self is nil) or cancel from a reachable path"
            } else {
                severity = configuration.severity(for: .taskNonterminatingSelf)
                note =
                    "the task retains self until it completes — which it may never do; capture [weak self] and exit when self is nil, or make cancellation reachable"
            }
            return Finding(
                rule: .taskNonterminatingSelf,
                severity: severity,
                path: path,
                line: spawn.position.line,
                column: spawn.position.column,
                message: "potentially non-terminating Task captures self strongly\(implicitly)",
                note: note
            )
        }
    }
}
