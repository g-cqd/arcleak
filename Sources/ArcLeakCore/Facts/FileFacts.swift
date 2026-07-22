/// The complete, `Sendable` extraction result for one source file. The syntax
/// tree is dropped as soon as this is built — memory stays bounded by facts.
public struct FileFacts: Sendable, Codable {
    public let path: String
    public var types: [TypeFacts]
    public var directives: [SuppressionDirective]

    public init(path: String, types: [TypeFacts] = [], directives: [SuppressionDirective] = []) {
        self.path = path
        self.types = types
        self.directives = directives
    }
}
