/// `.assign(to: \.…, on: self)` with the cancellable stored on `self`. Apple's
/// documentation is explicit: "The Subscribers.Assign instance created by this
/// operator maintains a strong reference to `object`" — with a never-completing
/// upstream (`@Published`, `Timer.publish`) this is a closed cycle.
struct CombineAssignSelfCycleRule: Rule {
    static let emits: [RuleID] = [.combineAssignSelfCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        // Same XCTest exemption as the sink rule: per-test instances are
        // framework-held for the run regardless; in-test cycles are noise.
        guard !type.inheritedTypeNames.contains("XCTestCase") else { return [] }
        return type.apiCalls.compactMap { call in
            guard call.kind == .combineAssignOn,
                call.targetIsSelf,
                call.consumption.storesIntoSelf,
                call.upstreamFiniteness != .finite
            else { return nil }

            // Assign releases `object` when the upstream completes — with an
            // unknown upstream, hedge to warning.
            let severity: Severity =
                call.upstreamFiniteness == .infinite
                ? configuration.severity(for: .combineAssignSelfCycle) : .warning
            return Finding(
                rule: .combineAssignSelfCycle,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "retain cycle: assign(to:on: self) retains self strongly while self stores the cancellable (self → cancellable → Assign → self)",
                note:
                    "assign to a @Published projection with assign(to: &$property) (no cancellable, no strong object reference), or use sink with [weak self]"
            )
        }
    }
}
