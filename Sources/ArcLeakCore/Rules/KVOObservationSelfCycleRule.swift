/// `self.observation = player.observe(\.rate) { _, _ in self.… }` — the
/// NSKeyValueObservation keeps its change handler, the handler keeps `self`,
/// and `self` keeps the observation: a closed cycle, the sink proof applied to
/// KVO. Foundation: "invalidate() will be called automatically when an
/// NSKeyValueObservation is deinited" — which never happens inside the cycle.
///
/// Gated on the observed object being `self` or a member of `self`, the shape
/// of the public fixes (wikipedia-ios@9db7aa718d); the observation token must
/// be stored on `self`.
struct KVOObservationSelfCycleRule: Rule {
    static let emits: [RuleID] = [.kvoObservationSelfCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        return type.apiCalls.compactMap { call in
            guard call.kind == .kvoObserve,
                call.targetIsSelf || call.receiverIsSelfMember,
                call.closureSelfCapture?.isStrong == true,
                call.consumption.storesIntoSelf
            else { return nil }
            return Finding(
                rule: .kvoObservationSelfCycle,
                severity: configuration.severity(for: .kvoObservationSelfCycle),
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "retain cycle: the KVO change handler captures self strongly and the NSKeyValueObservation is stored on self (self → observation → handler → self)",
                note:
                    "the observation invalidates only when deinited, which the cycle prevents; capture [weak self] in the change handler, or invalidate() it from a reachable path"
            )
        }
    }
}
