/// A call site matching one of the knowledge-base API shapes, with the facts a
/// rule needs: how the attached closure captures `self`, whether the call's
/// target is `self`, and where the returned token went.
public struct APICallFact: Sendable, Equatable, Codable {
    public enum Kind: Sendable, Hashable, Codable {
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
        /// User-KB contract: the call returns a lifetime token that must be
        /// owned (associated value = diagnostic name).
        case userTokenProducer(String)
    }

    /// Whether a Combine upstream provably completes. `Subscribers.Sink`
    /// releases its closures on the terminal event, so strong-self sinks over
    /// *finite* pipelines are transient keep-alives, not cycles; over
    /// never-completing upstreams (subjects, `@Published`, `Timer.publish`)
    /// the cycle is permanent.
    public enum UpstreamFiniteness: String, Sendable, Equatable, Codable {
        case finite
        case infinite
        case unknown
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
    /// Only meaningful for `combineSink`/`combineAssignOn`.
    public let upstreamFiniteness: UpstreamFiniteness
    /// Chain-root member name (`subject` in `subject.map{…}.sink`), used to
    /// resolve subject-backed properties once the whole type is collected.
    public let upstreamRootMember: String?
    /// Capture analysis of the trailing/`using:`/`block:` closure, when present.
    public let closureSelfCapture: SelfCaptureKind?
    /// True when the strong capture's only evidence is `self` in a NESTED
    /// closure's capture list (`sink { Task { [weak self] … } }`) — the outer
    /// closure still captures `self` strongly to build the weak box, but the
    /// body shows no bare `self`; diagnostics must explain the trap.
    public let selfCaptureViaNestedListOnly: Bool
    public let consumption: ResultConsumption

    public init(
        kind: Kind,
        position: SourcePosition,
        repeats: Bool?,
        targetIsSelf: Bool,
        receiverIsSelfMember: Bool = false,
        upstreamFiniteness: UpstreamFiniteness = .unknown,
        upstreamRootMember: String? = nil,
        closureSelfCapture: SelfCaptureKind?,
        selfCaptureViaNestedListOnly: Bool = false,
        consumption: ResultConsumption
    ) {
        self.kind = kind
        self.position = position
        self.repeats = repeats
        self.targetIsSelf = targetIsSelf
        self.receiverIsSelfMember = receiverIsSelfMember
        self.upstreamFiniteness = upstreamFiniteness
        self.upstreamRootMember = upstreamRootMember
        self.closureSelfCapture = closureSelfCapture
        self.selfCaptureViaNestedListOnly = selfCaptureViaNestedListOnly
        self.consumption = consumption
    }

    /// Copy with resolved finiteness (per-type post-pass for subject-backed
    /// chain roots).
    public func withUpstreamFiniteness(_ finiteness: UpstreamFiniteness) -> APICallFact {
        APICallFact(
            kind: kind,
            position: position,
            repeats: repeats,
            targetIsSelf: targetIsSelf,
            receiverIsSelfMember: receiverIsSelfMember,
            upstreamFiniteness: finiteness,
            upstreamRootMember: upstreamRootMember,
            closureSelfCapture: closureSelfCapture,
            selfCaptureViaNestedListOnly: selfCaptureViaNestedListOnly,
            consumption: consumption
        )
    }

    /// Copy with reclassified consumption (method-close post-pass for
    /// escaping locals). Copy methods, not field-list rebuilds: a rebuild
    /// silently drops any field added later (it happened).
    public func withConsumption(_ consumption: ResultConsumption) -> APICallFact {
        APICallFact(
            kind: kind,
            position: position,
            repeats: repeats,
            targetIsSelf: targetIsSelf,
            receiverIsSelfMember: receiverIsSelfMember,
            upstreamFiniteness: upstreamFiniteness,
            upstreamRootMember: upstreamRootMember,
            closureSelfCapture: closureSelfCapture,
            selfCaptureViaNestedListOnly: selfCaptureViaNestedListOnly,
            consumption: consumption
        )
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
        case .userTokenProducer:
            true
        }
    }
}
