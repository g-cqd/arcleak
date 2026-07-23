import SwiftParser
import SwiftSyntax

/// Applies the mechanical fix for strong-`self` closure captures: insert
/// `[weak self]` into the capture position and `guard let self else { return }`
/// as the first statement (valid under SE-0365 — existing implicit or explicit
/// `self` references keep compiling).
///
/// Deliberately conservative:
/// - only closure-shaped findings from the weak-self-fixable rules;
/// - only closures with no existing capture clause (an existing clause means a
///   human decision to revisit, not overwrite);
/// - `guard … else { return }` assumes a Void-returning closure — true for
///   every KB-matched handler shape; a non-Void closure fails to compile
///   loudly rather than being silently mis-fixed.
///
/// Edits are computed as text insertions and applied bottom-up so offsets
/// never shift under later edits.
public enum FixItApplier {
    /// Rules whose finding anchors at a closure fixable by weak-self insertion.
    public static let fixableRules: Set<RuleID> = [
        .storedClosureStrongSelf,
        .combineSinkSelfCycle,
        .timerRetainsSelf,
        .notificationObserverLeak,
        .dispatchSourceCycle,
        .taskNonterminatingSelf,
    ]

    public struct Application: Sendable {
        public let fixedSource: String
        public let appliedCount: Int
        public let skipped: [Finding]
    }

    /// Applies fixes for `findings` (already filtered to one file) to `source`.
    public static func apply(findings: [Finding], to source: String, path: String) -> Application {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let locator = ClosureLocator(viewMode: .sourceAccurate)
        locator.walk(tree)

        struct Insertion {
            let utf8Offset: Int
            let text: String
        }
        var insertions: [Insertion] = []
        var applied = 0
        var skipped: [Finding] = []
        // A closure already fixed by an earlier finding must not be fixed
        // again — two rules co-anchoring on one closure would otherwise write
        // `{ [weak self] [weak self] in … }`, which does not compile.
        var fixedClosures: Set<SyntaxIdentifier> = []

        for finding in findings where fixableRules.contains(finding.rule) {
            // The finding anchors at the call/closure start; the fixable
            // closure is the innermost one whose span contains that position.
            guard
                let closure = locator.closure(
                    forFindingAt: finding.line,
                    column: finding.column,
                    converter: converter
                ),
                closure.signature?.capture == nil
            else {
                skipped.append(finding)
                continue
            }
            // Already covered by another finding's fix — count it applied
            // (the closure gets `[weak self]`), don't insert twice.
            guard fixedClosures.insert(closure.id).inserted else {
                applied += 1
                continue
            }

            let indent = String(repeating: " ", count: max(0, finding.column + 3))
            if let signature = closure.signature {
                // `{ value in` → `{ [weak self] value in` + guard after `in`.
                insertions.append(
                    Insertion(
                        utf8Offset: signature.positionAfterSkippingLeadingTrivia.utf8Offset,
                        text: "[weak self] "
                    )
                )
                if let inKeyword = signature.inKeyword.presence == .present
                    ? signature.inKeyword : nil
                {
                    insertions.append(
                        Insertion(
                            utf8Offset: inKeyword.endPosition.utf8Offset,
                            text: "\n\(indent)guard let self else { return }"
                        )
                    )
                }
            } else {
                // `{ body` → `{ [weak self] in\n guard let self else { return } body`.
                insertions.append(
                    Insertion(
                        utf8Offset: closure.leftBrace.endPositionBeforeTrailingTrivia.utf8Offset,
                        text: " [weak self] in\n\(indent)guard let self else { return }"
                    )
                )
            }
            applied += 1
        }

        guard !insertions.isEmpty else {
            return Application(fixedSource: source, appliedCount: 0, skipped: skipped)
        }

        var bytes = Array(source.utf8)
        for insertion in insertions.sorted(by: { $0.utf8Offset > $1.utf8Offset }) {
            bytes.insert(contentsOf: Array(insertion.text.utf8), at: insertion.utf8Offset)
        }
        let fixed = String(decoding: bytes, as: UTF8.self)
        return Application(fixedSource: fixed, appliedCount: applied, skipped: skipped)
    }
}

/// Resolves a finding position to its fixable closure: call-anchored findings
/// (`Timer.scheduledTimer(…) { … }` anchors at `Timer`) resolve through the
/// call's attached closure; closure-anchored findings by innermost containment.
private final class ClosureLocator: SyntaxVisitor {
    private var closures: [ClosureExprSyntax] = []
    private var callsByPosition: [Position: FunctionCallExprSyntax] = [:]

    struct Position: Hashable {
        let line: Int
        let column: Int
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        closures.append(node)
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        calls.append(node)
        return .visitChildren
    }

    private var calls: [FunctionCallExprSyntax] = []

    func closure(
        forFindingAt line: Int,
        column: Int,
        converter: SourceLocationConverter
    ) -> ClosureExprSyntax? {
        if callsByPosition.isEmpty {
            for call in calls {
                let location = converter.location(for: call.positionAfterSkippingLeadingTrivia)
                callsByPosition[Position(line: location.line, column: location.column)] = call
            }
        }
        if let call = callsByPosition[Position(line: line, column: column)] {
            if let trailing = call.trailingClosure { return trailing }
            for argument in call.arguments {
                if let closure = argument.expression.as(ClosureExprSyntax.self) {
                    return closure
                }
            }
        }
        return innermostClosure(containing: line, column: column, converter: converter)
    }

    private func innermostClosure(
        containing line: Int,
        column: Int,
        converter: SourceLocationConverter
    ) -> ClosureExprSyntax? {
        var best: ClosureExprSyntax?
        var bestSpan = Int.max
        for closure in closures {
            let start = converter.location(for: closure.positionAfterSkippingLeadingTrivia)
            let end = converter.location(for: closure.endPosition)
            let contains =
                (start.line < line || (start.line == line && start.column <= column))
                && (end.line > line || (end.line == line && end.column >= column))
            guard contains else { continue }
            let span = closure.endPosition.utf8Offset - closure.position.utf8Offset
            if span < bestSpan {
                best = closure
                bestSpan = span
            }
        }
        return best
    }
}
