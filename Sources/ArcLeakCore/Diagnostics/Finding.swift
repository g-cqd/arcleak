/// A single diagnostic produced by a rule.
public struct Finding: Sendable, Codable, Equatable {
    public let rule: RuleID
    public let severity: Severity
    public let path: String
    public let line: Int
    public let column: Int
    public let message: String
    /// Optional secondary context (retention path, doc citation, fix hint).
    public let note: String?

    public init(
        rule: RuleID,
        severity: Severity,
        path: String,
        line: Int,
        column: Int,
        message: String,
        note: String? = nil
    ) {
        self.rule = rule
        self.severity = severity
        self.path = path
        self.line = line
        self.column = column
        self.message = message
        self.note = note
    }
}

extension Finding: Comparable {
    /// Deterministic report ordering: path, then position, then rule.
    public static func < (lhs: Finding, rhs: Finding) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        if lhs.column != rhs.column { return lhs.column < rhs.column }
        return lhs.rule.rawValue < rhs.rule.rawValue
    }
}
