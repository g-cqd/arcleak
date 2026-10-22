public import AemiJSON

/// A `Task { … }` / `Task.detached { … }` spawn site.
@JSONCodable
public struct TaskSpawnFact: Sendable, Equatable, Codable {
    public let position: SourcePosition
    public let selfCapture: SelfCaptureKind
    /// Body contains `while true` (boolean-literal condition) or a `for await` loop —
    /// the syntactic markers of a task that plausibly never completes.
    public let hasNonterminatingBody: Bool
    public let consumption: ResultConsumption
    /// Body contains `await` at its own level — a finite task that can still
    /// hold its captures for as long as the awaited work takes.
    public let bodyAwaits: Bool

    public init(
        position: SourcePosition,
        selfCapture: SelfCaptureKind,
        hasNonterminatingBody: Bool,
        consumption: ResultConsumption,
        bodyAwaits: Bool = false
    ) {
        self.position = position
        self.selfCapture = selfCapture
        self.hasNonterminatingBody = hasNonterminatingBody
        self.consumption = consumption
        self.bodyAwaits = bodyAwaits
    }
}
