import Foundation

/// One parsed `// arcleak:` comment.
///
/// Grammar (whitespace-tolerant, rule ids comma- or space-separated):
///
///     // arcleak:disable:this <rules|all> [-- reason]
///     // arcleak:disable:next <rules|all> [-- reason]
///     // arcleak:disable <rules|all>          (region start, to EOF if unbalanced)
///     // arcleak:enable <rules|all>           (region end)
///     // arcleak:deliberate [-- reason]       (sugar: disable:this all — marks an
///                                              intentional strong reference)
public struct SuppressionDirective: Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        case disableThis
        case disableNext
        /// `arcleak:deliberate` — covers its own line *and* the next, so it
        /// works both as a trailing comment and on the line above the code.
        case deliberate
        case regionDisable
        case regionEnable
    }

    /// Empty set means "all rules".
    public let rules: Set<RuleID>
    public let kind: Kind
    /// 1-based line the comment appears on.
    public let line: Int
    public let reason: String?

    public init(rules: Set<RuleID>, kind: Kind, line: Int, reason: String?) {
        self.rules = rules
        self.kind = kind
        self.line = line
        self.reason = reason
    }

    public func covers(_ rule: RuleID) -> Bool {
        rules.isEmpty || rules.contains(rule)
    }

    /// Parses the text of a single comment. Returns nil when the comment is not
    /// a arcleak directive. Unknown rule ids inside a directive are ignored
    /// (they may belong to a future arcleak version) — but if *nothing* parses,
    /// the directive suppresses nothing rather than everything.
    public static func parse(comment: String, line: Int) -> SuppressionDirective? {
        var text = comment
        if text.hasPrefix("//") { text.removeFirst(2) }
        if text.hasPrefix("/*") { text.removeFirst(2) }
        if text.hasSuffix("*/") { text.removeLast(2) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("arcleak:") else { return nil }
        text.removeFirst("arcleak:".count)

        var reason: String?
        if let range = text.range(of: "--") {
            reason = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            text = String(text[..<range.lowerBound])
        }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = parts.first else { return nil }
        let ruleWords = parts.dropFirst().flatMap { $0.split(separator: ",").map(String.init) }

        let kind: Kind
        switch verb {
        case "deliberate":
            return SuppressionDirective(rules: [], kind: .deliberate, line: line, reason: reason)
        case "disable:this": kind = .disableThis
        case "disable:next": kind = .disableNext
        case "disable": kind = .regionDisable
        case "enable": kind = .regionEnable
        default: return nil
        }

        if ruleWords.contains("all") || ruleWords.isEmpty {
            return SuppressionDirective(rules: [], kind: kind, line: line, reason: reason)
        }
        let rules = Set(ruleWords.compactMap(RuleID.init(rawValue:)))
        guard !rules.isEmpty else { return nil }
        return SuppressionDirective(rules: rules, kind: kind, line: line, reason: reason)
    }
}
