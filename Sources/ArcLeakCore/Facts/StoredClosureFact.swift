/// A closure literal that ends up stored on the enclosing instance: assigned to
/// a member (`self.handler = { … }` / `handler = { … }`), appended to a member
/// collection, or declared as a (lazy) stored-property initializer without
/// being immediately applied.
public struct StoredClosureFact: Sendable, Equatable, Codable {
    public let position: SourcePosition
    public let targetMember: String
    public let selfCapture: SelfCaptureKind

    public init(position: SourcePosition, targetMember: String, selfCapture: SelfCaptureKind) {
        self.position = position
        self.targetMember = targetMember
        self.selfCapture = selfCapture
    }
}
