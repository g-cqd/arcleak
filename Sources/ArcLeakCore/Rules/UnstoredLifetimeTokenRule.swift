/// The premature-release family: lifetime tokens (AnyCancellable, KVO
/// observation, observer handles, time-observer tokens) that are discarded or
/// die in a local — the work they own stops immediately and silently.
///
/// Emits `unstored-lifetime-token` for discards and `token-stored-in-local`
/// for scope-bound storage. Skips call sites already owned by a cycle rule
/// (strong-self NotificationCenter observers) so one bug gets one diagnostic.
struct UnstoredLifetimeTokenRule: Rule {
    static let emits: [RuleID] = [.unstoredLifetimeToken, .tokenStoredInLocal]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        // Test bodies hold tokens across a synchronous wait and rely on
        // scope-end cancellation as teardown — correct usage of the token,
        // not a premature release.
        guard !type.inheritedTypeNames.contains("XCTestCase") else { return [] }

        return type.apiCalls.compactMap { call in
            guard call.producesLifetimeToken else { return nil }
            if call.kind == .notificationAddObserverBlock, call.closureSelfCapture?.isStrong == true {
                return nil
            }
            // A weak/non-capturing block observer registered by a
            // process-lifetime owner (app delegate, `shared` singleton) is an
            // intentional register-forever: nothing is retained and removal is
            // never needed.
            if call.kind == .notificationAddObserverBlock,
                call.closureSelfCapture?.isStrong != true,
                Self.isProcessLifetimeOwner(type)
            {
                return nil
            }

            let token = tokenName(for: call.kind)
            switch call.consumption {
            case .discarded:
                return Finding(
                    rule: .unstoredLifetimeToken,
                    severity: configuration.severity(for: .unstoredLifetimeToken),
                    path: path,
                    line: call.position.line,
                    column: call.position.column,
                    message: "\(token) is discarded — \(consequence(for: call.kind))",
                    note:
                        "store it in a property of the owner (e.g. store(in:) into an instance Set<AnyCancellable>) for as long as the work should live"
                )
            case .storedToLocalOnly(let name):
                return Finding(
                    rule: .tokenStoredInLocal,
                    severity: configuration.severity(for: .tokenStoredInLocal),
                    path: path,
                    line: call.position.line,
                    column: call.position.column,
                    message:
                        "\(token) is stored in local '\(name)' and dies at scope end — \(consequence(for: call.kind))",
                    note: "move it to instance storage; a local cannot own work that outlives the call"
                )
            case .chainedStoreIn(memberOfSelf: false):
                return Finding(
                    rule: .tokenStoredInLocal,
                    severity: configuration.severity(for: .tokenStoredInLocal),
                    path: path,
                    line: call.position.line,
                    column: call.position.column,
                    message:
                        "\(token) is stored into a local collection via store(in:) and dies at scope end — \(consequence(for: call.kind))",
                    note: "store(in:) into a collection owned by the instance instead"
                )
            case .chainedStoreInCapturedLocal(let name):
                // The escaping capture keeps the box alive with the
                // closure, so the claim is closure-tied lifetime plus
                // unbounded growth, not scope-death.
                return Finding(
                    rule: .tokenStoredInLocal,
                    severity: configuration.severity(for: .tokenStoredInLocal),
                    path: path,
                    line: call.position.line,
                    column: call.position.column,
                    message:
                        "\(token) is stored via local '\(name)', which an escaping closure captured — the subscription lives exactly as long as the closure, and nothing removes it from the collection",
                    note:
                        "every invocation adds an entry that is never removed (unbounded growth if the closure lives on); store into instance storage with explicit removal, or cancel after the work completes"
                )
            case .storedToSelfMember, .storedToLocalEscaping, .chainedStoreIn(memberOfSelf: true),
                .returned, .other:
                return nil
            }
        }
    }

    private static func isProcessLifetimeOwner(_ type: TypeFacts) -> Bool {
        !type.inheritedTypeNames.isDisjoint(with: ["UIApplicationDelegate", "NSApplicationDelegate"])
            || type.memberNames.contains("shared")
    }

    private static func tokenName(for kind: APICallFact.Kind) -> String {
        switch kind {
        case .combineSink, .combineAssignOn: "the AnyCancellable"
        case .notificationAddObserverBlock: "the observer token"
        case .kvoObserve: "the NSKeyValueObservation"
        case .periodicTimeObserver: "the time-observer token"
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler:
            "the token"
        case .userTokenProducer(let name), .userSinkWrapper(let name):
            name
        }
    }

    private static func consequence(for kind: APICallFact.Kind) -> String {
        switch kind {
        case .combineSink, .combineAssignOn:
            "AnyCancellable cancels on deinit, so the subscription ends before any value arrives"
        case .notificationAddObserverBlock:
            "the registration can never be removed (the center holds block and token until removal)"
        case .kvoObserve:
            "the observation invalidates immediately and no changes are delivered"
        case .periodicTimeObserver:
            "the observer cannot be removed and callbacks may stop or leak"
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler:
            "the work it owns stops immediately"
        case .userTokenProducer:
            "the work it owns stops immediately (user contract)"
        case .userSinkWrapper:
            "the AnyCancellable-like token cancels on deinit, so the subscription ends before any value arrives (user contract)"
        }
    }
}
