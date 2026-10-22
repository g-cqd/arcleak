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

// Gap 5: a closure handed to a method of a child that stores it in a file
// arcleak does not connect to this call (`list.configure(onSelect:)` keeping
// `onSelect` in a property). self → list → stored parameter → self is a real
// cycle, but proving it needs parameter-to-property flow across files.
final class ListScreen {
    let list = ListController()

    func setUp() {
        list.configure(onSelect: { self.open() })
    }

    func open() {}
}

// Gap 6: a back-reference typed as a supertype or a protocol. The child keeps
// its parent as `UIViewController` (or `any ChildOwner`), so the type-level
// ownership graph has no edge back to `ParentScreen` and finds no cycle.
protocol ChildOwner: AnyObject {}

final class ChildPanel {
    var host: UIViewController?
    var owner: (any ChildOwner)?
}

final class ParentScreen: UIViewController, ChildOwner {
    let panel = ChildPanel()

    func attach() {
        panel.host = self
        panel.owner = self
    }
}

// Gap 7: a repeating timer invalidated only in a teardown method that nothing
// may call. A reachable `invalidate()` silences timer-retains-self, so a
// `stop()` that is never called leaves run loop → timer → self in place.
final class Heartbeat {
    var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.beat()
        }
    }

    func stop() {
        timer?.invalidate()
    }

    func beat() {}
}

// Gap 8: an AsyncStream continuation stored on self, finished only in deinit,
// whose termination handler captures self: self → continuation → onTermination
// → self. The handler is set on the build closure's parameter, not on a member
// of self, so no stored-closure fact exists. (A consumer Task that captures
// self strongly in `for await` IS caught, by task-nonterminating-self.)
final class EventFeed {
    var continuation: AsyncStream<Int>.Continuation?
    var consumer: Task<Void, Never>?

    func start() {
        let stream = AsyncStream<Int> { c in
            c.onTermination = { _ in self.reset() }
            self.continuation = c
        }
        consumer = Task { [weak self] in
            for await value in stream {
                self?.handle(value)
            }
        }
    }

    func handle(_ value: Int) {}
    func reset() {}

    deinit {
        continuation?.finish()
        consumer?.cancel()
    }
}