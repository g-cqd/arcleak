/// What happened to the value returned by a call of interest (a lifetime token,
/// a Task handle, an observer handle).
public enum ResultConsumption: Sendable, Equatable, Codable {
    /// `_ = call(...)` or bare statement position — the token dies immediately.
    case discarded
    /// Assigned to a stored property of the enclosing type (directly or via `self.`).
    case storedToSelfMember(String)
    /// Bound to a function-local `let`/`var` and, per a same-function scan,
    /// never handed to longer-lived storage.
    case storedToLocalOnly(String)
    /// Bound to a local that later reaches member storage / `store(in:)` / return.
    case storedToLocalEscaping(String)
    /// Chained `.store(in: &collection)`.
    case chainedStoreIn(memberOfSelf: Bool)
    /// Chained `.store(in:)` into a local captured by an escaping closure —
    /// the box outlives the call with the closure, and nothing removes the
    /// token from it (recall-first: flagged with a lifetime hedge, not silent).
    case chainedStoreInCapturedLocal(String)
    case returned
    /// Passed as an argument, part of a larger expression, etc. — assume owned elsewhere.
    case other
}
