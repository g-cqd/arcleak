/// Repeating `Timer` / `CADisplayLink` anchored on a run loop while retaining
/// `self` (via `target:` or a strong block capture).
///
/// Anchor leak, not a cycle: "Run loops maintain strong references to their
/// timers", and the timer "maintains a strong reference to target until it
/// (the timer) is invalidated" (Foundation docs). If `invalidate()` is
/// reachable outside `deinit`, the lifecycle is managed and we stay silent.
/// If it exists *only* in `deinit`, the leak is definite — `deinit` can never
/// run while the run loop keeps `self` alive — and severity is forced to error.
struct TimerRetainsSelfRule: Rule {
    static let emits: [RuleID] = [.timerRetainsSelf]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.invalidate) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.invalidate)

        return type.apiCalls.compactMap { call in
            let retention: String
            switch call.kind {
            case .timerScheduledTarget where call.targetIsSelf && call.repeats != false:
                retention = "the timer retains self (target:) until invalidate()"
            case .timerScheduledBlock where call.repeats == true && call.closureSelfCapture?.isStrong == true:
                retention = "the repeating timer's block captures self strongly until invalidate()"
            case .displayLinkTarget where call.targetIsSelf:
                retention = "the display link retains its target (self) until invalidate()"
            default:
                return nil
            }

            let severity: Severity
            let note: String
            if deinitOnly {
                severity = .error
                note =
                    "invalidate() only appears in deinit — deinit can never run while the run loop keeps self alive, so this leak is definite; invalidate from a reachable path (e.g. viewDidDisappear/stop())"
            } else {
                severity = configuration.severity(for: .timerRetainsSelf)
                note =
                    "run loop → timer → self keeps self alive; no invalidate() found in this type — add one on a reachable path, or capture [weak self]"
            }
            return Finding(
                rule: .timerRetainsSelf,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message: "leak: \(retention), and the run loop retains the timer",
                note: note
            )
        }
    }
}
