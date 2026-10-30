public import AemiJSON

/// What analyzerkit's facts cache keeps for one file (roadmap 0018): its facts, or why it was not analysed.
///
/// The facts depend on the file's bytes and the `#if` configuration, user contracts and platforms, which salt the
/// cache; rules always re-run on them. Their test and generated flags hold what the content alone says, since what
/// the file's project says changes without the file changing.
@JSONCodable
public struct ExtractedFacts: Sendable, Codable {
    public let facts: FileFacts?
    /// Over the size cap, not UTF-8, nested too deeply: the reason, as the report shows it.
    public let degraded: String?

    public init(facts: FileFacts? = nil, degraded: String? = nil) {
        self.facts = facts
        self.degraded = degraded
    }
}
