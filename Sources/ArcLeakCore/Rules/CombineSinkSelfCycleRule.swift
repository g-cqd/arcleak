/// `publisher.sink { self.… }` stored into `self`'s cancellables — closed cycle:
/// self → cancellable set → AnyCancellable → sink closure → self.
struct CombineSinkSelfCycleRule: Rule {
    static let emits: [RuleID] = [.combineSinkSelfCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        // XCTestCase cycles fire like any other — test instances never
        // deinit during a run, so leaked ones accumulate; the note names the
        // test context so deliberate assertion plumbing can be accepted.
        let isTestCase = type.inheritedTypeNames.contains("XCTestCase")
        return type.apiCalls.compactMap { call in
            guard call.kind == .combineSink,
                call.closureSelfCapture?.isStrong == true,
                call.consumption.storesIntoSelf,
                call.upstreamFiniteness != .finite
            else { return nil }

            let severity: Severity
            var note: String
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
            var message =
                "retain cycle: sink closure captures self strongly and its AnyCancellable is stored on self (self → cancellable → closure → self)"
            if call.selfCaptureViaNestedListOnly {
                // The dev sees only a nested [weak self] and will disbelieve a
                // bare "captures self strongly" — spell the mechanism out.
                message =
                    "retain cycle: the sink closure captures self strongly — its only `self` sits in a nested closure's capture list, and forming that nested [weak self] box forces the sink closure itself to capture self strongly (self → cancellable → closure → self)"
                note = "the nested [weak self] does not protect the outer closure; " + note
            }
            if isTestCase {
                note +=
                    " — XCTest holds test instances for the whole run, so this instance never deinits; if it is deliberate assertion plumbing, accept it with // @al:accept"
            }
            return Finding(
                rule: .combineSinkSelfCycle,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message: message,
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
