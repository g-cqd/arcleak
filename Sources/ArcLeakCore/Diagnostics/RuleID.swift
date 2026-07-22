/// Stable public identifiers for every diagnostic rule.
///
/// These are API: they appear in config files, suppression comments, baselines,
/// and CI logs. Renaming a case's raw value is a breaking change.
public enum RuleID: String, CaseIterable, Sendable, Codable {
    case storedClosureStrongSelf = "stored-closure-strong-self"
    case timerRetainsSelf = "timer-retains-self"
    case notificationObserverLeak = "notification-observer-leak"
    case combineSinkSelfCycle = "combine-sink-self-cycle"
    case combineAssignSelfCycle = "combine-assign-self-cycle"
    case taskNonterminatingSelf = "task-nonterminating-self"
    case unstoredLifetimeToken = "unstored-lifetime-token"
    case tokenStoredInLocal = "token-stored-in-local"
    case mutualStrongProperties = "mutual-strong-properties"
    case urlSessionDelegateLeak = "urlsession-delegate-leak"
    case dispatchSourceCycle = "dispatch-source-cycle"
    case unownedOutlivesOwner = "unowned-outlives-owner"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
        switch self {
        case .storedClosureStrongSelf, .combineAssignSelfCycle, .combineSinkSelfCycle,
            .dispatchSourceCycle:
            .error
        case .timerRetainsSelf, .notificationObserverLeak, .taskNonterminatingSelf,
            .unstoredLifetimeToken, .tokenStoredInLocal, .mutualStrongProperties,
            .urlSessionDelegateLeak, .unownedOutlivesOwner:
            .warning
        }
    }

    /// One-line human description used by `arcleak rules`.
    public var summary: String {
        switch self {
        case .storedClosureStrongSelf:
            "A closure stored on `self` captures `self` strongly — guaranteed retain cycle"
        case .timerRetainsSelf:
            "A repeating Timer/CADisplayLink retains `self` (run loop → timer → self) with no reachable invalidate()"
        case .notificationObserverLeak:
            "Block-based NotificationCenter observer captures `self` strongly; the center holds the block until removal"
        case .combineSinkSelfCycle:
            "sink closure captures `self` strongly and the AnyCancellable is stored on `self`"
        case .combineAssignSelfCycle:
            "assign(to:on: self) retains `self` strongly while `self` stores the cancellable"
        case .taskNonterminatingSelf:
            "A non-terminating Task captures `self` strongly (Task bodies capture `self` implicitly)"
        case .unstoredLifetimeToken:
            "Lifetime token (AnyCancellable, observation, observer handle) is discarded — the work it owns stops immediately"
        case .tokenStoredInLocal:
            "Lifetime token stored in a function-local variable dies at scope end"
        case .mutualStrongProperties:
            "Strong stored properties between types close a potential cross-file retain cycle"
        case .urlSessionDelegateLeak:
            "URLSession created with delegate: self leaks until the session is explicitly invalidated (documented)"
        case .dispatchSourceCycle:
            "Dispatch source stored on self with a strong-self handler and no reachable cancel()"
        case .unownedOutlivesOwner:
            "[unowned self] in a closure held by an external anchor — traps if self deallocates first"
        }
    }

    /// Long-form explanation for `arcleak explain <rule-id>`: the retention
    /// contract, why it bites, and the doc-grounded fix.
    public var explanation: String {
        switch self {
        case .storedClosureStrongSelf:
            """
            A closure stored on `self` (property, lazy initializer, member collection)
            that captures `self` strongly is a guaranteed cycle: self → storage → closure
            → self. Neither side can deallocate; deinit never runs.

            Fix: `[weak self]` + `guard let self` in the closure. The Swift book blesses
            `[unowned self]` only when "the closure and the instance … will always be
            deallocated at the same time" (TSPL, Automatic Reference Counting).
            Value types are exempt: struct `self` is copied, not retained.
            """
        case .timerRetainsSelf:
            """
            Foundation: "Run loops maintain strong references to their timers", and a
            selector-based timer "maintains a strong reference to target until it (the
            timer) is invalidated". A repeating timer therefore anchors `self` to the run
            loop: RunLoop → timer → self. No user-visible cycle exists, yet `self` can
            never deallocate — and `invalidate()` in `deinit` is unreachable by
            construction, because deinit can't run while the chain holds `self`.

            Fix: invalidate from a reachable lifecycle path (stop()/viewDidDisappear), or
            capture `[weak self]` in the block form.
            """
        case .notificationObserverLeak:
            """
            Foundation, addObserver(forName:object:queue:using:): "The notification
            center copies the block. The notification center strongly holds the copied
            block until you remove the observer registration" — and it strongly holds the
            returned token too. A strong `self` capture means NotificationCenter → block
            → self until removal; removal that only exists in deinit can never run.

            The selector-based variant does NOT retain the observer — removing in deinit
            is fine there (that asymmetry is why the two APIs are matched differently).

            Fix: `[weak self]` in the block, or remove the observer from a reachable path.
            """
        case .combineSinkSelfCycle:
            """
            `sink` returns an AnyCancellable that owns the subscription, which owns the
            closure. Storing it on `self` while the closure captures `self` strongly
            closes the loop: self → cancellables → AnyCancellable → closure → self.
            AnyCancellable's deinit-cancel never fires — deinit is inside the cycle.

            Fix: `[weak self]` in the sink closure.
            """
        case .combineAssignSelfCycle:
            """
            Combine, assign(to:on:): "The Subscribers.Assign instance created by this
            operator maintains a strong reference to `object`, and sets it to nil when
            the upstream publisher completes." With a never-completing upstream
            (@Published, Timer.publish) and the cancellable stored on the same object,
            the cycle is closed and documented.

            Fix: `assign(to: &$property)` (the Published overload manages lifetime
            without an AnyCancellable), or `sink` with `[weak self]`.
            """
        case .taskNonterminatingSelf:
            """
            An unstructured Task retains its closure — and the closure's captures —
            until the task completes. `Task.init` is `@_implicitSelfCapture`: bare member
            access captures `self` strongly with no `self` token in source, so the
            compiler's explicit-self guard is deliberately absent here. A body that never
            completes (`while true`, `for await` over a never-finishing sequence) pins
            `self` forever; storing the handle on `self` makes it a cycle whose only exit
            is a cancel() that deinit can never reach.

            Fix: `[weak self]` and exit when self is nil, or cancel from a reachable
            path. Finite tasks are deliberately not flagged — lifetime extension is not
            a leak.
            """
        case .unstoredLifetimeToken:
            """
            Tokens returned by sink/assign, observe(\\.keyPath), block-based addObserver,
            and addPeriodicTimeObserver OWN the work they represent. Discarding one
            (`_ =`, statement position) ends that work immediately: AnyCancellable
            cancels on deinit, NSKeyValueObservation invalidates, and a discarded
            NotificationCenter token can never be unregistered.

            Fix: store the token in a property of the intended owner.
            """
        case .tokenStoredInLocal:
            """
            Same contract as unstored-lifetime-token, but the token dies at scope end
            instead of immediately: a function-local binding (or a local
            `store(in: &localSet)`) cannot own work that must outlive the call. ARC ends
            an object's lifetime at last use — locals are not ownership.

            Fix: move the token (or the collection) to instance storage.
            """
        case .mutualStrongProperties:
            """
            Strong stored properties whose types point at each other (A.b: B, B.a: A —
            across files) form a strongly-connected component in the ownership graph:
            instances CAN form a cycle no weak link breaks. This is type-level analysis:
            specific instances may still be acyclic, so review which side owns the other.

            Fix (TSPL): the shorter-lived side's back-reference becomes `weak`; use
            `unowned` only when the referent always outlives the holder.
            """
        case .urlSessionDelegateLeak:
            """
            Foundation, URLSession.init(configuration:delegate:delegateQueue:): "The
            session object keeps a strong reference to the delegate until your app exits
            or explicitly invalidates the session. If you do not invalidate the session
            … your app leaks memory until it exits." With delegate: self, the session
            anchors self — and invalidation that only exists in deinit can never run.

            Fix: call invalidateAndCancel() or finishTasksAndInvalidate() from a
            reachable path, or use the shared session / completion-handler APIs.
            """
        case .dispatchSourceCycle:
            """
            Dispatch sources Block_copy and hold their handlers until replaced or
            cancelled. A source stored on self whose handler captures self strongly is a
            closed cycle: self → source → handler → self. cancel() breaks it — but
            cancel() in deinit is unreachable from inside the cycle.

            Fix: `[weak self]` in the handler, or cancel() from a reachable path.
            """
        case .unownedOutlivesOwner:
            """
            The Swift book licenses `unowned` only when the referent "has the same
            lifetime or a longer lifetime" than the closure. A closure handed to an
            external anchor (repeating timer, NotificationCenter, periodic time
            observer) outlives arbitrary objects — if self deallocates before the anchor
            releases the closure, the next access traps deterministically.

            Fix: `[weak self]` for anchor-held closures; keep `unowned` for the
            book-blessed same-lifetime shape (closure stored on self, never escaping it).
            """
        }
    }
}
