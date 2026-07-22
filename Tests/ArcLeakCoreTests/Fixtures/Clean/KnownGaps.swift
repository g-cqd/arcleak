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
