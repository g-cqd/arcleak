public import Suppression

/// One parsed `@al:` / `@arcleak:` directive comment.
///
/// The `@` sigil marks an instruction to the analyzer; `al` and `arcleak` are
/// interchangeable namespaces. Grammar (whitespace-tolerant, rule ids comma-
/// or space-separated; `all` or no rule = every rule):
///
///     // @al:accept [rules] [-- reason]        accept the finding here AND on
///                                              the next line (works trailing
///                                              or on the line above the code)
///     // @al:accept:this [rules] [-- reason]   this line only
///     // @al:accept:next [rules] [-- reason]   next line only
///     // @al:disable [rules|all]               region start (to EOF if unbalanced)
///     // @al:enable  [rules|all]               region end
///
/// `@arcleak:` is an exact synonym for `@al:`.
public typealias SuppressionDirective = Suppression.Directive<RuleID>

extension Suppression.Directive where Rule == RuleID {
    /// The accepted namespace prefixes after the `@` sigil.
    public static var namespaces: [String] { arcLeakDirectiveNamespaces }

    /// Parses one comment. Returns nil when it isn't an `@al:`/`@arcleak:`
    /// directive. Unknown rule ids inside a directive are ignored (they may
    /// belong to a future version) — but if a rule-scoped verb names *only*
    /// unknown rules, the directive suppresses nothing rather than everything.
    public static func parse(comment: String, line: Int) -> Self? {
        grammar.parse(comment: comment, line: line, rule: RuleID.init(rawValue:))
    }

    static var grammar: DirectiveGrammar { arcLeakDirectiveGrammar }
}

// Stored once: a generic type cannot hold a static stored property.
private let arcLeakDirectiveNamespaces = ["al:", "arcleak:"]
private let arcLeakDirectiveGrammar = DirectiveGrammar(namespaces: arcLeakDirectiveNamespaces)
