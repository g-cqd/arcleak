public import ADJSON

/// 1-based line/column pair.
@JSONCodable
public struct SourcePosition: Sendable, Equatable, Codable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}
