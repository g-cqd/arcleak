// swift-format-ignore-file
// (Gap: strong alias captures — FIXED, moved to Leaks/ActorAndNested.swift.)
// Documented false-NEGATIVE candidates: real leaks the current analyzer does
// not see. Asserted silent so the ledger is executable — if detection lands,
// these move to Leaks/ with expect markers, and this file shrinks. Candidates
// for SIL confirmation and index-layer work.

// Gap 2: subscript stores on self collections.
final class SubscriptStore {
    var handlers: [Int: () -> Void] = [:]

    func arm() {
        handlers[0] = { self.fire() }
    }

    func fire() {}
}

// Gap 3: conditional (ternary) closure assignment.
final class TernaryStore {
    var onChange: (() -> Void)?
    let flag = true

    func arm() {
        onChange = flag ? { self.fire() } : nil
    }

    func fire() {}
}

// Gap 4: a bound-method reference as a VALUE inside a collection literal passed
// to a stored-property initializer (`self.router = Router([.k: self.method])`).
// This is the Stations PlaybackService shape: `self.handle` retains the owner
// and is buried in a dictionary handed to a constructor whose result is stored
// on self — a real cycle (owner → router → stored closure → owner). Proving it
// needs the constructed type's storage semantics (does Router retain the
// dictionary, and does the sink it feeds outlive the owner?), which is
// cross-type ownership arcleak does not track — flagging it unconditionally
// would false-positive on the many constructors that consume closures
// transiently. Direct bound-method storage (`self.handler = self.method`) and
// bound methods handed straight to a token API (`sink(receiveValue: handle)`)
// ARE caught — see Leaks/MethodReferenceCaptures.swift.
final class ReactionRouter {
    private var reactions: [Int: (Int) -> Void]
    init(_ reactions: [Int: (Int) -> Void]) { self.reactions = reactions }
}

final class RouterOwner {
    var router: ReactionRouter?

    init() {
        self.router = ReactionRouter([
            0: { [weak self] value in self?.handle(value) },
            1: self.handle,
            2: { value in _ = value },
        ])
    }

    func handle(_ value: Int) {}
}