/// A call site matching one of the knowledge-base API shapes, with the facts a
/// rule needs: how the attached closure captures `self`, whether the call's
/// target is `self`, and where the returned token went.
public struct APICallFact: Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        /// `Timer.scheduledTimer(withTimeInterval:repeats:block:)` — run loop retains the
        /// timer; the timer retains the block until `invalidate()`.
        case timerScheduledBlock
        /// `Timer.scheduledTimer(timeInterval:target:selector:userInfo:repeats:)` — the
        /// timer retains `target` until invalidated.
        case timerScheduledTarget
        /// `CADisplayLink(target:selector:)` — "the newly constructed display link
        /// retains the target".
        case displayLinkTarget
        /// `addObserver(forName:object:queue:using:)` — the center strongly holds the
        /// copied block and the returned token until removal.
        case notificationAddObserverBlock
        /// `Publisher.sink(...)` — returns an AnyCancellable that cancels on deinit.
        case combineSink
        /// `Publisher.assign(to:on:)` — Subscribers.Assign strongly retains `object`.
        case combineAssignOn
        /// `observe(\.keyPath, ...)` — returns NSKeyValueObservation.
        case kvoObserve
        /// `addPeriodicTimeObserver(forInterval:queue:using:)` — token must be retained
        /// and removed.
        case periodicTimeObserver
        /// `URLSession(configuration:delegate:delegateQueue:)` — "keeps a strong
        /// reference to the delegate until your app exits or explicitly invalidates
        /// the session … your app leaks memory until it exits."
        case urlSessionWithDelegate
        /// `setEventHandler`/`setCancelHandler` on a dispatch source — handlers are
        /// Block_copy-ed and held by the source until replaced or cancelled.
        case dispatchSourceHandler
    }

    public let kind: Kind
    public let position: SourcePosition
    /// `repeats:` argument when it is a boolean literal; nil when absent/dynamic.
    public let repeats: Bool?
    /// True when a `target:`/`on:`/`delegate:` style argument is literally `self`.
    public let targetIsSelf: Bool
    /// True when the call's receiver is a stored member of the enclosing type
    /// (`self.source.setEventHandler { … }`) — the edge self → receiver exists.
    public let receiverIsSelfMember: Bool
    /// Capture analysis of the trailing/`using:`/`block:` closure, when present.
    public let closureSelfCapture: SelfCaptureKind?
    public let consumption: ResultConsumption

    public init(
        kind: Kind,
        position: SourcePosition,
        repeats: Bool?,
        targetIsSelf: Bool,
        receiverIsSelfMember: Bool = false,
        closureSelfCapture: SelfCaptureKind?,
        consumption: ResultConsumption
    ) {
        self.kind = kind
        self.position = position
        self.repeats = repeats
        self.targetIsSelf = targetIsSelf
        self.receiverIsSelfMember = receiverIsSelfMember
        self.closureSelfCapture = closureSelfCapture
        self.consumption = consumption
    }

    /// Whether this API returns a token whose loss is itself a bug (§ premature release).
    public var producesLifetimeToken: Bool {
        switch kind {
        case .combineSink, .combineAssignOn, .notificationAddObserverBlock, .kvoObserve,
             .periodicTimeObserver:
            true
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
             .urlSessionWithDelegate, .dispatchSourceHandler:
            false
        }
    }
}
