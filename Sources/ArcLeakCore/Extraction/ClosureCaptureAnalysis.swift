import SwiftSyntax

/// Result of analyzing one closure literal for `self` capture semantics.
struct ClosureCaptureAnalysis: Sendable, Equatable {
    let selfCapture: SelfCaptureKind
    let hasNonterminatingBody: Bool
    /// True when the ONLY evidence for a strong capture is `self` in a nested
    /// closure's capture list (`sink { Task { [weak self] … } }`): the outer
    /// closure still captures `self` strongly to materialize the nested weak
    /// box, but the source shows no bare `self` — diagnostics must teach the
    /// trap or developers will verify by eye and disbelieve the finding.
    let strongViaNestedCaptureOnly: Bool

    /// Analyzes `closure` without type information.
    ///
    /// - An explicit capture-list entry for `self` decides the strength alone:
    ///   `[weak self]` stays weak even when the body uses implicit `self` after
    ///   `guard let self` (SE-0365), `[self]`/`[unowned self]` per SE-0269.
    /// - Without an entry, any lexical `self` in the body is a strong capture —
    ///   including `self` mentioned in a *nested* closure's capture list, which
    ///   forces this closure to capture `self` strongly to feed it (the
    ///   "nested closure trap").
    /// - `allowImplicitSelf` models `@_implicitSelfCapture` contexts (`Task {}`):
    ///   bare identifiers matching `memberNames` count as implicit self captures
    ///   unless locally shadowed.
    /// - Non-termination markers (`while true`, `for await`) are only counted at
    ///   the analyzed closure's own nesting level.
    static func analyze(
        closure: ClosureExprSyntax,
        memberNames: Set<String>,
        allowImplicitSelf: Bool
    ) -> ClosureCaptureAnalysis {
        if let listed = captureListEntryForSelf(closure) {
            let walker = BodyWalker(memberNames: [], allowImplicitSelf: false)
            walker.walk(closure.statements)
            return ClosureCaptureAnalysis(
                selfCapture: listed,
                hasNonterminatingBody: walker.sawNonterminatingLoop,
                strongViaNestedCaptureOnly: false
            )
        }

        let walker = BodyWalker(memberNames: memberNames, allowImplicitSelf: allowImplicitSelf)
        walker.walk(closure.statements)

        let capture: SelfCaptureKind
        if walker.sawExplicitSelf {
            capture = .strong(implicit: false)
        } else if allowImplicitSelf, walker.hasUnshadowedMemberReference {
            capture = .strong(implicit: true)
        } else {
            capture = .none
        }
        return ClosureCaptureAnalysis(
            selfCapture: capture,
            hasNonterminatingBody: walker.sawNonterminatingLoop,
            strongViaNestedCaptureOnly: !walker.sawDirectSelf && walker.sawNestedCaptureListSelf
        )
    }

    /// Whether `body` textually references `self` (explicitly, including
    /// nested capture lists) — powers local-function capture analysis and
    /// dead-weak detection.
    static func referencesSelfExplicitly(_ body: some SyntaxProtocol) -> Bool {
        let walker = BodyWalker(memberNames: [], allowImplicitSelf: false)
        walker.walk(body)
        return walker.sawExplicitSelf
    }

    private static func captureListEntryForSelf(_ closure: ClosureExprSyntax) -> SelfCaptureKind? {
        guard let items = closure.signature?.capture?.items else { return nil }
        for item in items {
            let isSelfEntry = item.name.text == "self" && item.initializer == nil
            // `[s = self]` aliases capture self too — with the alias's strength.
            let isSelfAlias =
                item.initializer?.value.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
            guard isSelfEntry || isSelfAlias else { continue }
            switch item.specifier?.specifier.text {
            case "weak": return .weak
            case "unowned": return .unowned
            default: return .strong(implicit: false)
            }
        }
        return nil
    }

    private init(
        selfCapture: SelfCaptureKind,
        hasNonterminatingBody: Bool,
        strongViaNestedCaptureOnly: Bool
    ) {
        self.selfCapture = selfCapture
        self.hasNonterminatingBody = hasNonterminatingBody
        self.strongViaNestedCaptureOnly = strongViaNestedCaptureOnly
    }
}

/// Single pass over a closure body collecting capture evidence.
private final class BodyWalker: SyntaxVisitor {
    private let memberNames: Set<String>
    private let allowImplicitSelf: Bool

    /// Bare `self` in the body (or `guard let self` shorthand) — excluding
    /// occurrences under a nested closure that REBINDS `self` in its capture
    /// list, where `self` refers to the rebinding, not the outer capture.
    private(set) var sawDirectSelf = false
    /// `self` only via a nested closure's capture list — still forces a strong
    /// capture of the analyzed closure, but with no `self` token in its body.
    private(set) var sawNestedCaptureListSelf = false
    var sawExplicitSelf: Bool { sawDirectSelf || sawNestedCaptureListSelf }
    /// Depth of enclosing nested closures whose capture lists rebind `self`.
    private var selfRebindingDepth = 0
    private var memberCandidates: Set<String> = []
    private var localNames: Set<String> = []
    private(set) var sawNonterminatingLoop = false
    /// Depth below the analyzed body: loops only count at depth 0.
    private var nestingDepth = 0

    var hasUnshadowedMemberReference: Bool {
        !memberCandidates.subtracting(localNames).isEmpty
    }

    init(memberNames: Set<String>, allowImplicitSelf: Bool) {
        self.memberNames = memberNames
        self.allowImplicitSelf = allowImplicitSelf
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if name == "self" {
            if selfRebindingDepth == 0 { sawDirectSelf = true }
            return .skipChildren
        }
        if allowImplicitSelf, memberNames.contains(name), !isMemberAccessName(node) {
            memberCandidates.insert(name)
        }
        return .skipChildren
    }

    /// `self` appearing in a nested closure's capture list is a use of *our*
    /// `self` — the nested rebinding does not undo our capture. Covers the
    /// bare entry (`[weak self]`), the explicitly-assigned spelling the 6.4
    /// compiler suggests to silence ImplicitStrongCapture
    /// (`[weak self = self]`), and aliases (`[weak s = self]`): a capture
    /// initializer is evaluated in the ENCLOSING scope, so its `self` is the
    /// outer one even though this node sits inside the rebound closure.
    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == "self", node.initializer == nil {
            sawNestedCaptureListSelf = true
            return .visitChildren
        }
        if node.initializer?.value.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
            sawNestedCaptureListSelf = true
            // Skip the initializer: its `self` must not be re-attributed to
            // the rebound inner scope by the depth gate.
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        nestingDepth += 1
        if Self.rebindsSelf(node) { selfRebindingDepth += 1 }
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) {
        nestingDepth -= 1
        if Self.rebindsSelf(node) { selfRebindingDepth -= 1 }
    }

    /// A capture-list entry named `self` (weak, unowned, or `[self]`) rebinds
    /// `self` for the closure's body — bare `self` inside refers to it.
    private static func rebindsSelf(_ node: ClosureExprSyntax) -> Bool {
        node.signature?.capture?.items.contains { $0.name.text == "self" } == true
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        nestingDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        nestingDepth -= 1
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        if nestingDepth == 0,
            node.conditions.count == 1,
            let condition = node.conditions.first,
            let literal = condition.condition.as(BooleanLiteralExprSyntax.self),
            literal.literal.text == "true"
        {
            sawNonterminatingLoop = true
        }
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if nestingDepth == 0, node.awaitKeyword != nil {
            sawNonterminatingLoop = true
        }
        collectPatternNames(node.pattern)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            collectPatternNames(binding.pattern)
        }
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        // `guard let self` shorthand has no initializer expression — the
        // pattern itself is the use of the captured weak `self` (SE-0365).
        if node.initializer == nil,
            node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "self",
            selfRebindingDepth == 0
        {
            sawDirectSelf = true
        }
        collectPatternNames(node.pattern)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        localNames.insert(node.name.text)
        return .skipChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        localNames.insert((node.secondName ?? node.firstName).text)
        return .skipChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        localNames.insert((node.secondName ?? node.firstName).text)
        return .skipChildren
    }

    /// Explicit worklist rather than recursion (repo policy: our code stays
    /// iteration-only, so adversarially deep tuple patterns can't grow the
    /// stack even though SwiftParser bounds nesting first).
    private func collectPatternNames(_ pattern: PatternSyntax) {
        var worklist: [PatternSyntax] = [pattern]
        while let current = worklist.popLast() {
            if let identifier = current.as(IdentifierPatternSyntax.self) {
                localNames.insert(identifier.identifier.text)
            } else if let tuple = current.as(TuplePatternSyntax.self) {
                for element in tuple.elements {
                    worklist.append(element.pattern)
                }
            }
        }
    }

    /// True when `node` is the `.name` part of an explicit-base member access
    /// (`foo.bar` — `bar` is not a bare reference).
    private func isMemberAccessName(_ node: DeclReferenceExprSyntax) -> Bool {
        guard let parent = node.parent?.as(MemberAccessExprSyntax.self) else { return false }
        return parent.declName.id == node.id
    }
}
