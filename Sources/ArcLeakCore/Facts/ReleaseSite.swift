/// A call that releases a framework retention edge (`invalidate()`, `cancel()`,
/// `removeObserver(_:)`, session invalidation), and whether it sits in `deinit`.
///
/// The distinction is load-bearing: when the retention edge itself keeps `self`
/// alive (run loop → timer → self), a release that exists *only* in `deinit`
/// can never run — the leak is definite, and severity upgrades accordingly.
public struct ReleaseSite: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case invalidate
        case cancel
        case removeObserver
        case sessionInvalidate

        public init?(calleeName: String) {
            switch calleeName {
            case "invalidate": self = .invalidate
            case "cancel": self = .cancel
            case "removeObserver": self = .removeObserver
            case "invalidateAndCancel", "finishTasksAndInvalidate": self = .sessionInvalidate
            default: return nil
            }
        }
    }

    public let kind: Kind
    public let inDeinit: Bool

    public init(kind: Kind, inDeinit: Bool) {
        self.kind = kind
        self.inDeinit = inDeinit
    }
}
