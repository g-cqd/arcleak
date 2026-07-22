/// `publisher.sink { self.… }` stored into `self`'s cancellables — closed cycle:
/// self → cancellable set → AnyCancellable → sink closure → self.
struct CombineSinkSelfCycleRule: Rule {
    static let emits: [RuleID] = [.combineSinkSelfCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        return type.apiCalls.compactMap { call in
            guard call.kind == .combineSink,
                call.closureSelfCapture?.isStrong == true,
                call.consumption.storesIntoSelf,
                call.upstreamFiniteness != .finite
            else { return nil }

            let severity: Severity
            let note: String
            switch call.upstreamFiniteness {
            case .infinite:
                severity = configuration.severity(for: .combineSinkSelfCycle)
                note =
                    "capture [weak self] in the sink closure; the upstream never completes, so only explicit cancel() can break the cycle — deinit cannot"
            case .unknown, .finite:
                severity = .warning
                note =
                    "capture [weak self]; upstream completion could not be determined — the cycle persists until the publisher completes or cancel() runs"
            }
            return Finding(
                rule: .combineSinkSelfCycle,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "retain cycle: sink closure captures self strongly and its AnyCancellable is stored on self (self → cancellable → closure → self)",
                note: note
            )
        }
    }
}

extension ResultConsumption {
    /// The token ends up owned by `self` (member assignment or `store(in:)` on a member).
    var storesIntoSelf: Bool {
        switch self {
        case .storedToSelfMember: true
        case .chainedStoreIn(let memberOfSelf): memberOfSelf
        default: false
        }
    }
}
