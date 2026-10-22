public import AemiJSON

/// A closure literal that ends up stored on the enclosing instance: assigned to
/// a member (`self.handler = { … }` / `handler = { … }`), appended to a member
/// collection, or declared as a (lazy) stored-property initializer without
/// being immediately applied.
@JSONCodable
public struct StoredClosureFact: Sendable, Equatable, Codable {
    public let position: SourcePosition
    public let targetMember: String
    public let selfCapture: SelfCaptureKind
    /// `handler = self.method` — a bound method value; no capture-list syntax
    /// exists, so the fix is wrapping in a closure.
    public let isMethodReference: Bool
    /// The stored property of `self` that holds the closure's owner when the
    /// closure is stored one level down (`self.toolbar.onTap = { … }` gives
    /// "toolbar"); nil when the closure is stored on `self` itself.
    public let ownedChild: String?

    public init(
        position: SourcePosition,
        targetMember: String,
        selfCapture: SelfCaptureKind,
        isMethodReference: Bool = false,
        ownedChild: String? = nil
    ) {
        self.position = position
        self.targetMember = targetMember
        self.selfCapture = selfCapture
        self.isMethodReference = isMethodReference
        self.ownedChild = ownedChild
    }
}
