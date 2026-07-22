/// 1-based line/column pair.
public struct SourcePosition: Sendable, Equatable, Codable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}
