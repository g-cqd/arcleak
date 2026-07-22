/// `self.source.setEventHandler { self.… }` — dispatch sources Block_copy and
/// hold their handlers until replaced or cancelled, so a source stored on
/// `self` with a strong-`self` handler is a closed cycle:
/// self → source → handler → self. Reachable `cancel()` means a managed
/// lifecycle — silent. Absent or deinit-only `cancel()` cannot break the cycle.
struct DispatchSourceCycleRule: Rule {
    static let emits: [RuleID] = [.dispatchSourceCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.cancel) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.cancel)

        return type.apiCalls.compactMap { call in
            guard call.kind == .dispatchSourceHandler,
                call.receiverIsSelfMember,
                call.closureSelfCapture?.isStrong == true
            else { return nil }

            let note =
                deinitOnly
                ? "cancel() only appears in deinit — unreachable from inside the cycle; capture [weak self] or cancel from a reachable path"
                : "no cancel() found in this type — capture [weak self] in the handler or cancel the source from a reachable path"
            return Finding(
                rule: .dispatchSourceCycle,
                severity: configuration.severity(for: .dispatchSourceCycle),
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "retain cycle: dispatch source stored on self holds a handler that captures self strongly (self → source → handler → self)",
                note: note
            )
        }
    }
}
