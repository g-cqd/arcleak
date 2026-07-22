/// `publisher.sink { self.… }` stored into `self`'s cancellables — closed cycle:
/// self → cancellable set → AnyCancellable → sink closure → self.
struct CombineSinkSelfCycleRule: Rule {
    static let emits: [RuleID] = [.combineSinkSelfCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        return type.apiCalls.compactMap { call in
            guard call.kind == .combineSink,
                  call.closureSelfCapture?.isStrong == true,
                  call.consumption.storesIntoSelf
            else { return nil }
            return Finding(
                rule: .combineSinkSelfCycle,
                severity: configuration.severity(for: .combineSinkSelfCycle),
                path: path,
                line: call.position.line,
                column: call.position.column,
                message: "retain cycle: sink closure captures self strongly and its AnyCancellable is stored on self (self → cancellable → closure → self)",
                note: "capture [weak self] in the sink closure; the cycle holds until cancel() or upstream completion — permanent with never-completing upstreams (@Published, subjects); deinit cannot break it"
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
