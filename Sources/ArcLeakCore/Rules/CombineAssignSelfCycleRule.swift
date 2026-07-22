/// `.assign(to: \.…, on: self)` with the cancellable stored on `self`. Apple's
/// documentation is explicit: "The Subscribers.Assign instance created by this
/// operator maintains a strong reference to `object`" — with a never-completing
/// upstream (`@Published`, `Timer.publish`) this is a closed cycle.
struct CombineAssignSelfCycleRule: Rule {
    static let emits: [RuleID] = [.combineAssignSelfCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        return type.apiCalls.compactMap { call in
            guard call.kind == .combineAssignOn,
                  call.targetIsSelf,
                  call.consumption.storesIntoSelf
            else { return nil }
            return Finding(
                rule: .combineAssignSelfCycle,
                severity: configuration.severity(for: .combineAssignSelfCycle),
                path: path,
                line: call.position.line,
                column: call.position.column,
                message: "retain cycle: assign(to:on: self) retains self strongly while self stores the cancellable (self → cancellable → Assign → self)",
                note: "assign to a @Published projection with assign(to: &$property) (no cancellable, no strong object reference), or use sink with [weak self]"
            )
        }
    }
}
