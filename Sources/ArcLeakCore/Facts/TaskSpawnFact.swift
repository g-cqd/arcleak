public import ADJSON

/// A `Task { … }` / `Task.detached { … }` spawn site.
@JSONCodable
public struct TaskSpawnFact: Sendable, Equatable, Codable {
    public let position: SourcePosition
    public let selfCapture: SelfCaptureKind
    /// Body contains `while true` (boolean-literal condition) or a `for await` loop —
    /// the syntactic markers of a task that plausibly never completes.
    public let hasNonterminatingBody: Bool
    public let consumption: ResultConsumption

    public init(
        position: SourcePosition,
        selfCapture: SelfCaptureKind,
        hasNonterminatingBody: Bool,
        consumption: ResultConsumption
    ) {
        self.position = position
        self.selfCapture = selfCapture
        self.hasNonterminatingBody = hasNonterminatingBody
        self.consumption = consumption
    }
}
