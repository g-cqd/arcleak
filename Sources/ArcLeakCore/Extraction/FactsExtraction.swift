import SwiftParser
import SwiftSyntax

/// Parses one file and extracts `FileFacts`. The tree lives only for the
/// duration of this call.
public enum FactsExtraction {
    public static func extract(path: String, source: String) -> FileFacts {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)

        let members = MemberCollector()
        members.walk(tree)

        let extractor = FactsExtractor(
            path: path,
            converter: converter,
            memberTable: members.table
        )
        extractor.walk(tree)

        var facts = extractor.finish()
        facts.directives = scanDirectives(tree: tree, converter: converter)
        return facts
    }

    /// One token sweep collecting `// arcleak:` comment directives with their lines.
    static func scanDirectives(
        tree: SourceFileSyntax,
        converter: SourceLocationConverter
    ) -> [SuppressionDirective] {
        var directives: [SuppressionDirective] = []

        func scan(_ trivia: Trivia, startingAt startOffset: Int) {
            var offset = startOffset
            for piece in trivia {
                switch piece {
                case .lineComment(let text), .blockComment(let text),
                     .docLineComment(let text), .docBlockComment(let text):
                    let line = converter.location(for: AbsolutePosition(utf8Offset: offset)).line
                    if let directive = SuppressionDirective.parse(comment: text, line: line) {
                        directives.append(directive)
                    }
                default:
                    break
                }
                offset += piece.sourceLength.utf8Length
            }
        }

        for token in tree.tokens(viewMode: .sourceAccurate) {
            scan(token.leadingTrivia, startingAt: token.position.utf8Offset)
            scan(token.trailingTrivia, startingAt: token.endPositionBeforeTrailingTrivia.utf8Offset)
        }
        return directives
    }
}

/// Second pass: walks the tree with the member table in hand and produces the
/// per-type facts the rules consume.
final class FactsExtractor: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private let memberTable: [String: MemberCollector.Entry]

    private var typeStack: [String] = []
    private var methodStack: [MethodContext] = []
    private var collected: [String: CollectedFacts] = [:]

    private static let fileScopeKey = "<file-scope>"

    private struct CollectedFacts {
        var storedProperties: [StoredPropertyFact] = []
        var storedClosures: [StoredClosureFact] = []
        var apiCalls: [APICallFact] = []
        var taskSpawns: [TaskSpawnFact] = []
        var releaseSites: [ReleaseSite] = []
    }

    private struct MethodContext {
        let nodeID: SyntaxIdentifier
        let isDeinit: Bool
        var apiCalls: [APICallFact] = []
        var taskSpawns: [TaskSpawnFact] = []
        var localUses: [String: Int] = [:]
    }

    init(path: String, converter: SourceLocationConverter, memberTable: [String: MemberCollector.Entry]) {
        self.path = path
        self.converter = converter
        self.memberTable = memberTable
        super.init(viewMode: .sourceAccurate)
    }

    func finish() -> FileFacts {
        var facts = FileFacts(path: path)
        for (name, collectedFacts) in collected.sorted(by: { $0.key < $1.key }) {
            var type = TypeFacts(name: name, isReferenceType: memberTable[name]?.isReferenceType)
            type.memberNames = memberTable[name]?.members ?? []
            type.inheritedTypeNames = memberTable[name]?.inheritedTypes ?? []
            type.storedProperties = collectedFacts.storedProperties
            type.storedClosures = collectedFacts.storedClosures
            type.apiCalls = collectedFacts.apiCalls
            type.taskSpawns = collectedFacts.taskSpawns
            type.releaseSites = collectedFacts.releaseSites
            facts.types.append(type)
        }
        return facts
    }

    // MARK: - Type scope

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(MemberCollector.extendedTypeName(node.extendedType))
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    // MARK: - Method scope

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushMethodIfTopLevel(node, isDeinit: false)
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) { popMethod(node) }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushMethodIfTopLevel(node, isDeinit: false)
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) { popMethod(node) }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushMethodIfTopLevel(node, isDeinit: true)
        return .visitChildren
    }

    override func visitPost(_ node: DeinitializerDeclSyntax) { popMethod(node) }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushMethodIfTopLevel(node, isDeinit: false)
        return .visitChildren
    }

    override func visitPost(_ node: AccessorDeclSyntax) { popMethod(node) }

    /// Implicit getters (`var x: T { … }` with no `get` keyword) produce no
    /// `AccessorDeclSyntax` — the body hangs off the binding directly. They
    /// still need a method context, or local-escape analysis silently skips
    /// them (found via dogfooding: `defer { _ = cancellable }` went uncounted).
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if case .getter = node.accessorBlock?.accessors {
            methodStack.append(MethodContext(nodeID: node.id, isDeinit: false))
        }
        return .visitChildren
    }

    override func visitPost(_ node: PatternBindingSyntax) { popMethod(node) }

    /// Local functions nested inside a method share the enclosing method's
    /// context; only direct type members (or file-level functions) open one.
    private func pushMethodIfTopLevel(_ node: some SyntaxProtocol, isDeinit: Bool) {
        guard methodStack.isEmpty || node.parent?.is(MemberBlockItemSyntax.self) == true else { return }
        methodStack.append(MethodContext(nodeID: node.id, isDeinit: isDeinit))
    }

    private func popMethod(_ node: some SyntaxProtocol) {
        guard let top = methodStack.last, top.nodeID == node.id else { return }
        methodStack.removeLast()
        let context = top

        func finalize(_ consumption: ResultConsumption) -> ResultConsumption {
            if case .storedToLocalOnly(let name) = consumption,
               context.localUses[name, default: 0] > 0 {
                return .storedToLocalEscaping(name)
            }
            return consumption
        }

        let key = typeStack.last ?? Self.fileScopeKey
        for call in context.apiCalls {
            collected[key, default: CollectedFacts()].apiCalls.append(
                APICallFact(
                    kind: call.kind,
                    position: call.position,
                    repeats: call.repeats,
                    targetIsSelf: call.targetIsSelf,
                    receiverIsSelfMember: call.receiverIsSelfMember,
                    closureSelfCapture: call.closureSelfCapture,
                    consumption: finalize(call.consumption)
                )
            )
        }
        for spawn in context.taskSpawns {
            collected[key, default: CollectedFacts()].taskSpawns.append(
                TaskSpawnFact(
                    position: spawn.position,
                    selfCapture: spawn.selfCapture,
                    hasNonterminatingBody: spawn.hasNonterminatingBody,
                    consumption: finalize(spawn.consumption)
                )
            )
        }
    }

    // MARK: - Reference counting for local-escape analysis

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if !methodStack.isEmpty {
            methodStack[methodStack.count - 1].localUses[node.baseName.text, default: 0] += 1
        }
        return .skipChildren
    }

    // MARK: - Stored-property closures (`lazy var x = { … }`)

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.parent?.is(MemberBlockItemSyntax.self) == true, typeStack.last != nil else {
            return .visitChildren
        }
        recordStoredProperties(node)
        for binding in node.bindings {
            guard
                let closure = binding.initializer?.value.as(ClosureExprSyntax.self),
                let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else { continue }
            let analysis = ClosureCaptureAnalysis.analyze(
                closure: closure,
                memberNames: currentMemberNames,
                allowImplicitSelf: false
            )
            appendStoredClosure(
                StoredClosureFact(
                    position: position(of: closure),
                    targetMember: name,
                    selfCapture: analysis.selfCapture
                )
            )
        }
        return .visitChildren
    }

    /// Emits `StoredPropertyFact`s for instance storage: skips `static`/`class`
    /// members and computed properties (an accessor block with anything beyond
    /// `willSet`/`didSet` observers means no storage). Type names come from the
    /// annotation, or from a direct `= TypeName(...)` initializer as a
    /// same-module inference (capitalized callee only).
    private func recordStoredProperties(_ node: VariableDeclSyntax) {
        guard let typeName = typeStack.last else { return }
        let modifierNames = node.modifiers.map(\.name.text)
        guard !modifierNames.contains("static"), !modifierNames.contains("class") else { return }

        let strength: ReferenceStrength = if modifierNames.contains("weak") {
            .weak
        } else if modifierNames.contains("unowned") {
            .unowned
        } else {
            .strong
        }

        for binding in node.bindings {
            if let accessorBlock = binding.accessorBlock {
                switch accessorBlock.accessors {
                case .getter:
                    continue
                case .accessors(let accessors):
                    let observersOnly = accessors.allSatisfy {
                        ["willSet", "didSet"].contains($0.accessorSpecifier.text)
                    }
                    if !observersOnly { continue }
                }
            }
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                continue
            }

            var typeNames: [String] = []
            if let annotation = binding.typeAnnotation {
                typeNames = TypeNameExtractor.nominalNames(in: annotation.type)
            } else if let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
                      let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
                      reference.baseName.text.first?.isUppercase == true {
                typeNames = [reference.baseName.text]
            }

            collected[typeName, default: CollectedFacts()].storedProperties.append(
                StoredPropertyFact(
                    name: name,
                    strength: strength,
                    referencedTypeNames: typeNames,
                    position: position(of: binding)
                )
            )
        }
    }

    // MARK: - Assignments (`self.handler = { … }`, `handler = { … }`)

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard
            elements.count == 3,
            elements[1].is(AssignmentExprSyntax.self),
            let closure = unwrapped(elements[2]).as(ClosureExprSyntax.self),
            let member = memberOfSelfName(elements[0])
        else { return .visitChildren }

        let analysis = ClosureCaptureAnalysis.analyze(
            closure: closure,
            memberNames: currentMemberNames,
            allowImplicitSelf: false
        )
        appendStoredClosure(
            StoredClosureFact(
                position: position(of: closure),
                targetMember: member,
                selfCapture: analysis.selfCapture
            )
        )
        return .visitChildren
    }

    // MARK: - Calls: KB matching, Task spawns, release sites, member-collection appends

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        recordReleaseSiteIfAny(node)
        recordAppendedClosureIfAny(node)

        if let spawn = matchTaskSpawn(node) {
            appendTaskSpawn(spawn)
            return .visitChildren
        }
        if let call = matchKnowledgeBase(node) {
            appendAPICall(call)
        }
        return .visitChildren
    }

    // MARK: - KB matching helpers

    private func matchKnowledgeBase(_ node: FunctionCallExprSyntax) -> APICallFact? {
        let labels = node.arguments.compactMap { $0.label?.text }

        func argument(_ label: String) -> ExprSyntax? {
            node.arguments.first { $0.label?.text == label }?.expression
        }
        func isSelf(_ expr: ExprSyntax?) -> Bool {
            expr?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
        }
        func repeatsLiteral() -> Bool? {
            guard let literal = argument("repeats")?.as(BooleanLiteralExprSyntax.self) else {
                return nil
            }
            return literal.literal.text == "true"
        }
        func attachedClosure(labels closureLabels: [String]) -> ClosureExprSyntax? {
            if let trailing = node.trailingClosure { return trailing }
            for label in closureLabels {
                if let closure = argument(label)?.as(ClosureExprSyntax.self) { return closure }
            }
            return nil
        }

        let kind: APICallFact.Kind
        var targetIsSelf = false
        var receiverIsSelfMember = false
        var closureLabels: [String] = []

        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let callee = member.declName.baseName.text
            let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text
            switch callee {
            case "scheduledTimer" where base == "Timer" && labels.contains("target"):
                kind = .timerScheduledTarget
                targetIsSelf = isSelf(argument("target"))
            case "scheduledTimer" where base == "Timer":
                kind = .timerScheduledBlock
                closureLabels = ["block"]
            case "addObserver" where labels.contains("forName"):
                kind = .notificationAddObserverBlock
                closureLabels = ["using"]
            case "sink":
                kind = .combineSink
                closureLabels = ["receiveValue"]
            case "assign" where labels.contains("to") && labels.contains("on"):
                kind = .combineAssignOn
                targetIsSelf = isSelf(argument("on"))
            case "observe" where node.arguments.first?.expression.is(KeyPathExprSyntax.self) == true:
                kind = .kvoObserve
                closureLabels = ["changeHandler"]
            case "addPeriodicTimeObserver":
                kind = .periodicTimeObserver
                closureLabels = ["using"]
            case "setEventHandler", "setCancelHandler", "setRegistrationHandler":
                kind = .dispatchSourceHandler
                closureLabels = ["handler"]
                if let base = member.base {
                    receiverIsSelfMember = memberOfSelfName(base) != nil
                }
            default:
                return nil
            }
        } else if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
                  reference.baseName.text == "CADisplayLink",
                  labels.contains("target") {
            kind = .displayLinkTarget
            targetIsSelf = isSelf(argument("target"))
        } else if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
                  reference.baseName.text == "URLSession",
                  labels.contains("configuration"),
                  labels.contains("delegate") {
            kind = .urlSessionWithDelegate
            targetIsSelf = isSelf(argument("delegate"))
        } else {
            return nil
        }

        var closureCapture: SelfCaptureKind?
        if let closure = attachedClosure(labels: closureLabels) {
            closureCapture = ClosureCaptureAnalysis.analyze(
                closure: closure,
                memberNames: currentMemberNames,
                allowImplicitSelf: false
            ).selfCapture
        }

        return APICallFact(
            kind: kind,
            position: position(of: node),
            repeats: repeatsLiteral(),
            targetIsSelf: targetIsSelf,
            receiverIsSelfMember: receiverIsSelfMember,
            closureSelfCapture: closureCapture,
            consumption: classifyConsumption(of: node)
        )
    }

    private func matchTaskSpawn(_ node: FunctionCallExprSyntax) -> TaskSpawnFact? {
        let isTask: Bool
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            isTask = reference.baseName.text == "Task"
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                  member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Task",
                  member.declName.baseName.text == "detached" {
            isTask = true
        } else {
            isTask = false
        }
        guard isTask, let closure = node.trailingClosure else { return nil }

        // `Task.init` is `@_implicitSelfCapture`: bare member references capture
        // `self` strongly with no `self` token in source.
        let analysis = ClosureCaptureAnalysis.analyze(
            closure: closure,
            memberNames: currentMemberNames,
            allowImplicitSelf: true
        )
        return TaskSpawnFact(
            position: position(of: node),
            selfCapture: analysis.selfCapture,
            hasNonterminatingBody: analysis.hasNonterminatingBody,
            consumption: classifyConsumption(of: node)
        )
    }

    private func recordReleaseSiteIfAny(_ node: FunctionCallExprSyntax) {
        guard
            let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            let kind = ReleaseSite.Kind(calleeName: member.declName.baseName.text)
        else { return }
        let site = ReleaseSite(kind: kind, inDeinit: methodStack.last?.isDeinit ?? false)
        collected[typeStack.last ?? Self.fileScopeKey, default: CollectedFacts()]
            .releaseSites.append(site)
    }

    /// `self.handlers.append { … }` / `handlers.append(closure)` — a closure
    /// entering a member collection is a stored closure.
    private func recordAppendedClosureIfAny(_ node: FunctionCallExprSyntax) {
        guard
            let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            ["append", "insert"].contains(member.declName.baseName.text),
            let base = member.base,
            let collection = memberOfSelfName(base)
        else { return }

        var closure = node.trailingClosure
        if closure == nil {
            closure = node.arguments.first?.expression.as(ClosureExprSyntax.self)
        }
        guard let closure else { return }

        let analysis = ClosureCaptureAnalysis.analyze(
            closure: closure,
            memberNames: currentMemberNames,
            allowImplicitSelf: false
        )
        appendStoredClosure(
            StoredClosureFact(
                position: position(of: closure),
                targetMember: collection,
                selfCapture: analysis.selfCapture
            )
        )
    }

    // MARK: - Consumption classification

    private func classifyConsumption(of call: FunctionCallExprSyntax) -> ResultConsumption {
        var current = Syntax(call)
        while let parent = current.parent {
            if let tryExpr = parent.as(TryExprSyntax.self), tryExpr.expression.id == current.id {
                current = parent
                continue
            }
            if let awaitExpr = parent.as(AwaitExprSyntax.self), awaitExpr.expression.id == current.id {
                current = parent
                continue
            }
            if let member = parent.as(MemberAccessExprSyntax.self), member.base?.id == current.id {
                guard
                    let chained = member.parent?.as(FunctionCallExprSyntax.self),
                    chained.calledExpression.id == member.id
                else { return .other }
                if member.declName.baseName.text == "store",
                   let argument = chained.arguments.first,
                   argument.label?.text == "in" {
                    let target = argument.expression.as(InOutExprSyntax.self)?.expression
                    let memberOfSelf = target.flatMap(memberOfSelfName) != nil
                    return .chainedStoreIn(memberOfSelf: memberOfSelf)
                }
                current = Syntax(chained)
                continue
            }
            // `a = expr` parses as SequenceExpr(ExprList[a, =, expr]): the call's
            // parent is the element list, and the sequence sits one level up.
            if let list = parent.as(ExprListSyntax.self),
               let sequence = list.parent?.as(SequenceExprSyntax.self) {
                return classifyAssignment(sequence: sequence, rhsID: current.id)
            }
            if let sequence = parent.as(SequenceExprSyntax.self) {
                return classifyAssignment(sequence: sequence, rhsID: current.id)
            }
            if let initializer = parent.as(InitializerClauseSyntax.self),
               initializer.value.id == current.id {
                return classifyBinding(initializer)
            }
            if parent.is(ReturnStmtSyntax.self) { return .returned }
            if parent.is(CodeBlockItemSyntax.self) { return .discarded }
            return .other
        }
        return .other
    }

    private func classifyAssignment(sequence: SequenceExprSyntax, rhsID: SyntaxIdentifier) -> ResultConsumption {
        let elements = Array(sequence.elements)
        guard
            elements.count == 3,
            elements[1].is(AssignmentExprSyntax.self),
            unwrapped(elements[2]).id == rhsID || elements[2].id == rhsID
        else { return .other }

        let lhs = elements[0]
        if lhs.is(DiscardAssignmentExprSyntax.self) { return .discarded }
        if let member = memberOfSelfName(lhs) { return .storedToSelfMember(member) }
        if let local = lhs.as(DeclReferenceExprSyntax.self) {
            return .storedToLocalOnly(local.baseName.text)
        }
        return .other
    }

    private func classifyBinding(_ initializer: InitializerClauseSyntax) -> ResultConsumption {
        guard
            let binding = initializer.parent?.as(PatternBindingSyntax.self),
            let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
            let variableDecl = binding.parent?.parent?.as(VariableDeclSyntax.self)
        else { return .other }
        if variableDecl.parent?.is(MemberBlockItemSyntax.self) == true {
            return .storedToSelfMember(name)
        }
        return .storedToLocalOnly(name)
    }

    // MARK: - Shared helpers

    private var currentMemberNames: Set<String> {
        guard let typeName = typeStack.last else { return [] }
        return memberTable[typeName]?.members ?? []
    }

    /// `self.x` → "x"; bare `x` when `x` is a member of the enclosing type → "x".
    private func memberOfSelfName(_ expr: some ExprSyntaxProtocol) -> String? {
        if let member = ExprSyntax(expr).as(MemberAccessExprSyntax.self),
           member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
            return member.declName.baseName.text
        }
        if let reference = ExprSyntax(expr).as(DeclReferenceExprSyntax.self),
           currentMemberNames.contains(reference.baseName.text) {
            return reference.baseName.text
        }
        return nil
    }

    private func unwrapped(_ expr: ExprSyntax) -> ExprSyntax {
        var current = expr
        while true {
            if let tryExpr = current.as(TryExprSyntax.self) {
                current = tryExpr.expression
            } else if let awaitExpr = current.as(AwaitExprSyntax.self) {
                current = awaitExpr.expression
            } else {
                return current
            }
        }
    }

    private func position(of node: some SyntaxProtocol) -> SourcePosition {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return SourcePosition(line: location.line, column: location.column)
    }

    private func appendStoredClosure(_ fact: StoredClosureFact) {
        collected[typeStack.last ?? Self.fileScopeKey, default: CollectedFacts()]
            .storedClosures.append(fact)
    }

    private func appendAPICall(_ fact: APICallFact) {
        if methodStack.isEmpty {
            collected[typeStack.last ?? Self.fileScopeKey, default: CollectedFacts()]
                .apiCalls.append(fact)
        } else {
            methodStack[methodStack.count - 1].apiCalls.append(fact)
        }
    }

    private func appendTaskSpawn(_ fact: TaskSpawnFact) {
        if methodStack.isEmpty {
            collected[typeStack.last ?? Self.fileScopeKey, default: CollectedFacts()]
                .taskSpawns.append(fact)
        } else {
            methodStack[methodStack.count - 1].taskSpawns.append(fact)
        }
    }
}
