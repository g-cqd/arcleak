public import ADJSON

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

    public init(
        position: SourcePosition,
        targetMember: String,
        selfCapture: SelfCaptureKind,
        isMethodReference: Bool = false
    ) {
        self.position = position
        self.targetMember = targetMember
        self.selfCapture = selfCapture
        self.isMethodReference = isMethodReference
    }
}
