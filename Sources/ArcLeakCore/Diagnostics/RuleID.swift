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
    case deadWeakCapture = "dead-weak-capture"
    case delegateStrongProperty = "delegate-strong-property"
    case webviewScriptHandlerCycle = "webview-script-handler-cycle"
    case kvoObservationSelfCycle = "kvo-observation-self-cycle"
    case secCleanupInUnreachableDeinit = "sec-cleanup-in-unreachable-deinit"
    case secSessionInCycle = "sec-session-in-cycle"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
        switch self {
        case .storedClosureStrongSelf, .combineAssignSelfCycle, .combineSinkSelfCycle,
            .dispatchSourceCycle:
            .error
        case .timerRetainsSelf, .notificationObserverLeak, .taskNonterminatingSelf,
            .unstoredLifetimeToken, .tokenStoredInLocal, .mutualStrongProperties,
            .urlSessionDelegateLeak, .unownedOutlivesOwner, .deadWeakCapture,
            .delegateStrongProperty, .webviewScriptHandlerCycle, .kvoObservationSelfCycle:
            .warning
        case .secCleanupInUnreachableDeinit, .secSessionInCycle:
            .note
        }
    }

    /// Opt-in rules ship disabled; enable per-rule in `.arcleak.json`.
    public var enabledByDefault: Bool {
        switch self {
        case .deadWeakCapture, .delegateStrongProperty, .secCleanupInUnreachableDeinit, .secSessionInCycle:
            false
        default: true
        }
    }

    /// SARIF `properties.tags` of the security pack's rules; nil for the
    /// others.
    public var securityTags: [String]? {
        switch self {
        case .secCleanupInUnreachableDeinit: ["security", "CWE-401", "CWE-226"]
        case .secSessionInCycle: ["security", "CWE-401"]
        default: nil
        }
    }

    /// One-line human description used by `arcleak rules`.
    public var summary: String {
        switch self {
        case .storedClosureStrongSelf:
            "A closure stored on `self`, or on a child `self` owns, captures `self` strongly — retain cycle"
        case .timerRetainsSelf:
            "A repeating Timer/CADisplayLink retains `self` (run loop → timer → self) with no reachable invalidate()"
        case .notificationObserverLeak:
            "Block-based NotificationCenter observer captures `self` strongly; the center holds the block until removal"
        case .combineSinkSelfCycle:
            "sink (or Rx/SwiftSignalKit subscription) closure captures `self` strongly and its token is stored on `self`"
        case .combineAssignSelfCycle:
            "assign(to:on: self) retains `self` strongly while `self` stores the cancellable"
        case .taskNonterminatingSelf:
            "A non-terminating Task, or a stored Task cancelled only in deinit, captures `self` strongly"
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
        case .deadWeakCapture:
            "[weak self] whose body never uses self — capture-list noise (opt-in)"
        case .delegateStrongProperty:
            "Strong stored property named/typed like a delegate — likely back-reference cycle (opt-in)"
        case .webviewScriptHandlerCycle:
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        case .secCleanupInUnreachableDeinit:
            "deinit wipes bytes, invalidates a session, closes a handle or cancels work in a type kept alive by a reported cycle (opt-in)"
        case .secSessionInCycle:
            "Tags cycle findings on a type holding a WKWebView, LAContext, ASWebAuthenticationSession or delegate URLSession (opt-in)"
        case .kvoObservationSelfCycle:
            "observe(\\.keyPath) change handler captures `self` strongly and the NSKeyValueObservation is stored on `self`"
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

            One level down the proof is the same: `self.toolbar.onTap = { self… }`
            (or `.append`) where `toolbar` is a strong stored property of `self` gives
            self → toolbar → closure → self. Reported as a warning, since a child may
            clear its callback after firing. Weak or unowned children, children held
            in a local, and children typed as a struct or enum of the same file are
            not reported.
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

            Reactive subscriptions close the same loop: RxSwift `subscribe(onNext:)`,
            `bind` or `drive` followed by `.disposed(by: self.bag)`, and SwiftSignalKit
            `self.disposable.set(signal.start(next:))`, give self → bag/disposable →
            subscription → closure → self; the bag disposes only in its own deinit.
            These report as warnings, since completion of the source cannot be read
            from the call; finite sources (`Single`, `Completable`, `Maybe`, `just`,
            `take(1)`, `first()`) stay silent. Other spellings are declared with the
            `disposeBag` and `signalDisposable` contract templates.

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

            A finite task whose body awaits is flagged in one shape only: its handle is
            stored on `self` and its only `cancel()` sits in deinit. That cancel cannot
            run while the task holds `self`, so `self` lives as long as the awaited
            work, forever if it never returns — the deinit-only idiom of
            timer-retains-self. Reported at the configured severity (warning by
            default), since the awaited work usually does return.

            Fix: `[weak self]` and exit when self is nil, or cancel from a reachable
            path. Other finite tasks are deliberately not flagged — lifetime extension
            is not a leak.
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
        case .deadWeakCapture:
            """
            A `[weak self]` capture whose body never references `self` does nothing —
            it is cargo-cult ceremony that buries the capture lists that matter.
            Opt-in tidiness rule; enable it once real captures are under control.

            Fix: delete the capture list entry.
            """
        case .delegateStrongProperty:
            """
            A strong stored property whose name or type reads as a delegate/data
            source is the classic back-reference: the owner outlives the observer,
            and strong-both-ways closes a cycle. Name-heuristic while class-bound
            protocol facts wait for the index layer — hence opt-in.

            Fix (TSPL): `weak var delegate: …?` — the delegate outlives or matches
            the delegating object's lifetime only when ownership says so.
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
        case .webviewScriptHandlerCycle:
            """
            `userContentController.add(self, name:)` (or `add(_:contentWorld:name:)`,
            `addScriptMessageHandler(_:contentWorld:name:)`) registers `self` as a
            script message handler. The user content controller
            keeps the handler until `removeScriptMessageHandler(forName:)` or
            `removeAllScriptMessageHandlers()` runs, and the web view's configuration
            keeps the controller: WKWebView → configuration → userContentController →
            self. When `self` also keeps the web view, its configuration or its content
            controller in a strong stored property, the loop is closed and a removal
            that only exists in deinit can never run: that is reported as an error.
            A type that keeps none of them is not in a cycle (the controller keeps it
            only while the web view lives): a deinit-only removal is silent there, and
            a missing removal is a warning about the observed retention.

            Apple's documentation for add(_:name:) lists the removal methods next to it
            but does not state the retention; this rule rests on observed behaviour.
            Public fixes register a weak proxy instead of `self` for this reason
            (firefox-ios@4d83f60171, element-x-ios@f8d094516d).

            Fix: remove the handler from a reachable teardown path (viewDidDisappear,
            a close() method), or register a proxy that holds `self` weakly.
            """
        case .kvoObservationSelfCycle:
            """
            `self.observation = object.observe(\\.keyPath) { … self … }`, whatever the
            observed object is: the cycle runs through the observation, not through
            the observed object. The returned NSKeyValueObservation keeps its change
            handler, which keeps `self`, which keeps the observation: self →
            observation → change handler → self. Foundation,
            NSKeyValueObservation.invalidate(): "invalidate() will be called
            automatically when an NSKeyValueObservation is deinited" — and the
            observation is deinited only after `self`, which the cycle prevents.

            A reachable `invalidate()` in the type silences the rule, as it does for
            timers. invalidate() stops the notifications, but the observation keeps
            its handler until it is released (apple/swift@d6b4691dc8,
            NSObject.swift), so release it too.

            Fix: `[weak self]` in the change handler, or invalidate() and release
            (`observation = nil`) the observation from a reachable path. A public fix
            of this shape: wikipedia-ios@9db7aa718d.
            """
        case .secCleanupInUnreachableDeinit:
            """
            Security pack, opt-in (CWE-401, CWE-226). A deinit that zeroes memory
            (`resetBytes(in:)`, `memset`), invalidates a session or timer, closes a
            handle, cancels work or removes an observer is cleanup the type relies
            on. When the same type is kept alive by a cycle arcleak reports
            (stored-closure-strong-self, combine-sink-self-cycle,
            task-nonterminating-self, …), deinit never runs: secrets stay in memory,
            sessions stay valid, handles stay open. The finding is a note anchored
            on the cycle finding it depends on.

            Covers the cycles reported per type; the cross-type cycles of
            mutual-strong-properties are not linked to deinit bodies.

            Enable with `{"rules": {"sec-cleanup-in-unreachable-deinit": {"enabled":
            true}}}` (arcleak 0.10.2 and earlier reject the id).

            Fix: break the cycle, and move cleanup that must happen to a reachable
            teardown path (logout, close(), viewDidDisappear).
            """
        case .secSessionInCycle:
            """
            Security pack, opt-in (CWE-401). A cycle that keeps a web view, an
            LAContext, an ASWebAuthenticationSession or a URL session with a
            delegate alive keeps authenticated state alive past the screen or flow
            that owned it. This rule adds no finding of its own: when enabled, every
            cycle finding on a type that keeps one of those objects (a strong stored
            property of that declared type, a script message handler registration, a
            URLSession created with a delegate) gets a note naming them.

            Types are matched by name; cross-type cycles of mutual-strong-properties
            are not tagged.

            Enable with `{"rules": {"sec-session-in-cycle": {"enabled": true}}}`
            (arcleak 0.10.2 and earlier reject the id).

            Fix: break the cycle the note is attached to.
            """
        }
    }
}
