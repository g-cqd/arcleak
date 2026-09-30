public import AemiJSON

/// The complete, `Sendable` extraction result for one source file. The syntax
/// tree is dropped as soon as this is built — memory stays bounded by facts.
@JSONCodable
public struct FileFacts: Sendable, Codable {
    public let path: String
    public var types: [TypeFacts]
    public var directives: [SuppressionDirective]
    /// Lines only debug builds (`#if DEBUG`) or previews compile.
    public var regionSpans: [RegionSpanFact]
    /// Whether the file is test code (imports a test framework, or a test path).
    public var isTestCode: Bool
    /// Whether a generator wrote the file.
    public var isGenerated: Bool

    public init(
        path: String,
        types: [TypeFacts] = [],
        directives: [SuppressionDirective] = [],
        regionSpans: [RegionSpanFact] = [],
        isTestCode: Bool = false,
        isGenerated: Bool = false
    ) {
        self.path = path
        self.types = types
        self.directives = directives
        self.regionSpans = regionSpans
        self.isTestCode = isTestCode
        self.isGenerated = isGenerated
    }
}
