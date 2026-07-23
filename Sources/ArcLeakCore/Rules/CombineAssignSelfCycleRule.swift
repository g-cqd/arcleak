/// `.assign(to: \.…, on: self)` with the cancellable stored on `self`. Apple's
/// documentation is explicit: "The Subscribers.Assign instance created by this
/// operator maintains a strong reference to `object`" — with a never-completing
/// upstream (`@Published`, `Timer.publish`) this is a closed cycle.
struct CombineAssignSelfCycleRule: Rule {
    static let emits: [RuleID] = [.combineAssignSelfCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        // XCTestCase cycles fire with a test-context note (see the sink
        // rule).
        let isTestCase = type.inheritedTypeNames.contains("XCTestCase")
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
            var note =
                "assign to a @Published projection with assign(to: &$property) (no cancellable, no strong object reference), or use sink with [weak self]"
            if isTestCase {
                note +=
                    " — XCTest holds test instances for the whole run, so this instance never deinits; if it is deliberate assertion plumbing, accept it with // @al:accept"
            }
            return Finding(
                rule: .combineAssignSelfCycle,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "retain cycle: assign(to:on: self) retains self strongly while self stores the cancellable (self → cancellable → Assign → self)",
                note: note
            )
        }
    }
}
