import ProjectModel
import Suppression
import SwiftIfConfig
import SwiftParser
import SwiftSyntax

/// Parses one file and extracts `FileFacts`. The tree lives only for the
/// duration of this call.
public enum FactsExtraction {
    public static func extract(
        path: String,
        source: String,
        defines: Set<String> = [],
        platforms: Set<String> = [],
        contracts: [Configuration.UserContract] = []
    ) -> FileFacts {
        extract(
            path: path, tree: Parser.parse(source: source), defines: defines, platforms: platforms, contracts: contracts
        )
    }

    /// As ``extract(path:source:defines:platforms:contracts:)``, from a tree already parsed: the caller checks its
    /// depth first (`SyntaxDepth`), since every walk below recurses once per level.
    static func extract(
        path: String,
        tree: SourceFileSyntax,
        defines: Set<String> = [],
        platforms: Set<String> = [],
        contracts: [Configuration.UserContract] = []
    ) -> FileFacts {
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let buildConfiguration = buildConfiguration(defines: defines, platforms: platforms)

        let members = MemberCollector(buildConfiguration: buildConfiguration)
        members.walk(tree)

        let extractor = FactsExtractor(
            path: path,
            converter: converter,
            memberTable: members.table,
            buildConfiguration: buildConfiguration,
            userContracts: contracts
        )
        extractor.walk(tree)

        var facts = extractor.finish()
        facts.directives = scanDirectives(tree: tree, converter: converter)
        facts.regionSpans = CodeRegionScanner.scan(tree, converter: converter).map(RegionSpanFact.init)
        facts.isTestCode = TestConventions.isTestFile(path: path, tree: tree)
        facts.isGenerated = GeneratedCode.isGenerated(path: path, tree: tree)
        return facts
    }

    /// Facts follow what a compile would see: the `os()` conditions of the
    /// project's platforms (the host's when none is known) plus the custom
    /// conditions, through analyzerkit's one recipe (ADR-0029), which fcheck
    /// and modeler read too. (`canImport` modules are not modeled yet —
    /// documented limitation.)
    static func buildConfiguration(
        defines: Set<String>,
        platforms: Set<String> = []
    ) -> StaticBuildConfiguration {
        CompilationConditions(defines: defines, platforms: platforms).buildConfiguration
    }

    /// One token sweep collecting `@al:`/`@arcleak:` comment directives with their lines.
    static func scanDirectives(
        tree: SourceFileSyntax,
        converter: SourceLocationConverter
    ) -> [SuppressionDirective] {
        SuppressionDirective.grammar.scan(tree: tree, converter: converter, parse: SuppressionDirective.parse)
    }
}

/// Second pass: walks the tree with the member table in hand and produces the
/// per-type facts the rules consume.
final class FactsExtractor: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private let memberTable: [String: MemberCollector.Entry]
    private let buildConfiguration: StaticBuildConfiguration
    private let userContracts: [Configuration.UserContract]

    private var typeStack: [String] = []
    private var methodStack: [MethodContext] = []
    private var collected: [String: CollectedFacts] = [:]

    private static let fileScopeKey = "<file-scope>"

    private struct CollectedFacts {
        var deadWeakCaptures: [SourcePosition] = []
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
        /// Local `func`s whose bodies reference `self` — passing one as a value
        /// captures `self` strongly with no capture-list syntax available.
        var selfReferencingLocalFunctions: Set<String> = []
        /// Locals (bindings + parameters) that shadow member names: a bare
        /// `handler = { … }` writing a *local* must never be read as member
        /// storage.
        var localDeclarations: Set<String> = []
        /// Closure-nesting depth at each local's declaration (first wins).
        /// `store(in:)` claims scope-death only when the store runs at the
        /// SAME depth — a deeper store means the local was captured by a
        /// closure that extends its lifetime.
        var localBindingDepths: [String: Int] = [:]
    }

    /// Closure-nesting depth below the current method body.
    private var closureDepth = 0

    init(
        path: String,
        converter: SourceLocationConverter,
        memberTable: [String: MemberCollector.Entry],
        buildConfiguration: StaticBuildConfiguration,
        userContracts: [Configuration.UserContract] = []
    ) {
        self.path = path
        self.converter = converter
        self.memberTable = memberTable
        self.buildConfiguration = buildConfiguration
        self.userContracts = userContracts
        super.init(viewMode: .sourceAccurate)
    }

    /// Mirror of `MemberCollector`'s handling: only the active clause's facts
    /// exist under this configuration.
    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        if let clause = node.activeClause(in: buildConfiguration).clause,
            let elements = clause.elements
        {
            walk(elements)
        }
        return .skipChildren
    }

    func finish() -> FileFacts {
        var facts = FileFacts(path: path)
        for (name, collectedFacts) in collected.sorted(by: { $0.key < $1.key }) {
            var type = TypeFacts(name: name, isReferenceType: memberTable[name]?.isReferenceType)
            type.memberNames = memberTable[name]?.members ?? []
            type.inheritedTypeNames = memberTable[name]?.inheritedTypes ?? []
            type.methodNames = memberTable[name]?.functionMembers ?? []
            type.attributeNames = memberTable[name]?.typeAttributes ?? []
            type.deadWeakCaptures = collectedFacts.deadWeakCaptures
            type.storedProperties = collectedFacts.storedProperties
            type.storedClosures = collectedFacts.storedClosures.filter { closure in
                guard let child = closure.ownedChild else { return true }
                return Self.isOwnedChild(child, properties: collectedFacts.storedProperties)
            }
            type.apiCalls = Self.resolveUpstreams(
                collectedFacts.apiCalls,
                properties: collectedFacts.storedProperties
            )
            type.taskSpawns = collectedFacts.taskSpawns
            type.releaseSites = collectedFacts.releaseSites
            facts.types.append(type)
        }
        return facts
    }

    /// A closure stored through `self.<child>.<member>` closes a cycle only
    /// when `self` owns the child: a strong stored property of this type. The
    /// child's type does not matter: a class child is kept by reference, and
    /// a struct child is stored inline in `self`, closure included.
    private static func isOwnedChild(_ child: String, properties: [StoredPropertyFact]) -> Bool {
        properties.contains { $0.name == child && $0.strength == .strong }
    }

    /// Post-pass once the whole type is collected: an unknown upstream whose
    /// chain root is a subject-backed or `@Published` property is infinite.
    private static func resolveUpstreams(
        _ calls: [APICallFact],
        properties: [StoredPropertyFact]
    ) -> [APICallFact] {
        let neverCompleting = Set(
            properties
                .filter { property in
                    property.hasPublishedAttribute
                        || property.referencedTypeNames.contains(where: subjectTypeNames.contains)
                }
                .map(\.name)
        )
        guard !neverCompleting.isEmpty else { return calls }
        return calls.map { call in
            guard call.upstreamFiniteness == .unknown,
                call.kind == .combineSink || call.kind == .combineAssignOn,
                let root = call.upstreamRootMember,
                neverCompleting.contains(root)
            else { return call }
            return call.withUpstreamFiniteness(.infinite)
        }
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
        let opened = pushMethodIfTopLevel(node, isDeinit: false)
        if opened {
            for parameter in node.signature.parameterClause.parameters {
                methodStack[methodStack.count - 1]
                    .localDeclarations.insert((parameter.secondName ?? parameter.firstName).text)
            }
        } else if !methodStack.isEmpty {
            if ClosureCaptureAnalysis.referencesSelfExplicitly(node) {
                methodStack[methodStack.count - 1]
                    .selfReferencingLocalFunctions.insert(node.name.text)
            }
            methodStack[methodStack.count - 1].localDeclarations.insert(node.name.text)
        }
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) { popMethod(node) }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let opened = pushMethodIfTopLevel(node, isDeinit: false)
        if opened {
            // Same shadowing discipline as `func`: `self.compositeId =
            // compositeId` writes the parameter, not a member-method value.
            for parameter in node.signature.parameterClause.parameters {
                methodStack[methodStack.count - 1]
                    .localDeclarations.insert((parameter.secondName ?? parameter.firstName).text)
            }
        }
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
    /// them (`defer { _ = cancellable }` counts as a use).
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if case .getter = node.accessorBlock?.accessors {
            methodStack.append(MethodContext(nodeID: node.id, isDeinit: false))
        }
        return .visitChildren
    }

    override func visitPost(_ node: PatternBindingSyntax) { popMethod(node) }

    /// Local functions nested inside a method share the enclosing method's
    /// context; only direct type members (or file-level functions) open one.
    @discardableResult
    private func pushMethodIfTopLevel(_ node: some SyntaxProtocol, isDeinit: Bool) -> Bool {
        guard methodStack.isEmpty || node.parent?.is(MemberBlockItemSyntax.self) == true else {
            return false
        }
        methodStack.append(MethodContext(nodeID: node.id, isDeinit: isDeinit))
        return true
    }

    private func popMethod(_ node: some SyntaxProtocol) {
        guard let top = methodStack.last, top.nodeID == node.id else { return }
        methodStack.removeLast()
        let context = top

        func finalize(_ consumption: ResultConsumption) -> ResultConsumption {
            if case .storedToLocalOnly(let name) = consumption,
                context.localUses[name, default: 0] > 0
            {
                return .storedToLocalEscaping(name)
            }
            return consumption
        }

        let key = typeStack.last ?? Self.fileScopeKey
        for call in context.apiCalls {
            collected[key, default: CollectedFacts()].apiCalls.append(
                call.withConsumption(finalize(call.consumption))
            )
        }
        for spawn in context.taskSpawns {
            collected[key, default: CollectedFacts()].taskSpawns.append(
                TaskSpawnFact(
                    position: spawn.position,
                    selfCapture: spawn.selfCapture,
                    hasNonterminatingBody: spawn.hasNonterminatingBody,
                    consumption: finalize(spawn.consumption),
                    bodyAwaits: spawn.bodyAwaits
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
            // A method-local binding shadows any member of the same name for
            // the rest of the context.
            if !methodStack.isEmpty {
                for binding in node.bindings {
                    if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                        methodStack[methodStack.count - 1].localDeclarations.insert(name)
                        if methodStack[methodStack.count - 1].localBindingDepths[name] == nil {
                            methodStack[methodStack.count - 1].localBindingDepths[name] =
                                closureDepth
                        }
                    }
                }
            }
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

        let strength: ReferenceStrength =
            if modifierNames.contains("weak") {
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
            } else if let call = binding.initializer?.value.as(FunctionCallExprSyntax.self) {
                // `= TypeName(...)` and `= TypeName<Args>(...)` both infer.
                var callee = call.calledExpression
                if let generic = callee.as(GenericSpecializationExprSyntax.self) {
                    callee = generic.expression
                }
                if let reference = callee.as(DeclReferenceExprSyntax.self),
                    reference.baseName.text.first?.isUppercase == true
                {
                    typeNames = [reference.baseName.text]
                }
            }

            let attributeNames = node.attributes.compactMap {
                $0.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            }

            collected[typeName, default: CollectedFacts()].storedProperties.append(
                StoredPropertyFact(
                    name: name,
                    strength: strength,
                    referencedTypeNames: typeNames,
                    hasPublishedAttribute: attributeNames.contains("Published"),
                    hasTransientAttribute: attributeNames.contains("Transient"),
                    position: position(of: binding)
                )
            )
        }
    }

    // MARK: - Assignments (`self.handler = { … }`, `handler = { … }`)

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self) else { return .visitChildren }
        let member: String
        let ownedChild: String?
        if let name = memberOfSelfName(elements[0]) {
            member = name
            ownedChild = nil
        } else if let target = ownedChildTarget(elements[0]) {
            member = "\(target.child).\(target.member)"
            ownedChild = target.child
        } else {
            return .visitChildren
        }

        if let closure = unwrapped(elements[2]).as(ClosureExprSyntax.self) {
            let analysis = ClosureCaptureAnalysis.analyze(
                closure: closure,
                memberNames: currentMemberNames,
                allowImplicitSelf: false
            )
            appendStoredClosure(
                StoredClosureFact(
                    position: position(of: closure),
                    targetMember: member,
                    selfCapture: analysis.selfCapture,
                    ownedChild: ownedChild
                )
            )
        } else if strongCaptureEquivalent(elements[2]) {
            appendStoredClosure(
                StoredClosureFact(
                    position: position(of: elements[2]),
                    targetMember: member,
                    selfCapture: .strong(implicit: false),
                    isMethodReference: true,
                    ownedChild: ownedChild
                )
            )
        }
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
        if let call = matchKnowledgeBase(node) ?? matchUserContract(node)
            ?? matchInferredTokenFactory(node)
        {
            appendAPICall(call)
        }
        if let store = matchUnconditionalContinuationStore(node) { appendAPICall(store) }
        return .visitChildren
    }

    // MARK: - Continuation stores (continuation-overwrite)

    private static let continuationMakers: Set<String> = [
        "withCheckedContinuation", "withCheckedThrowingContinuation",
        "withUnsafeContinuation", "withUnsafeThrowingContinuation",
    ]

    /// `member = continuation` in a `with…Continuation` closure, recorded only
    /// when the code holds no condition that could keep a second call out: none
    /// before the store in the closure, none before the call in the method, the
    /// call not nested in a closure or a branch, and no mention of the member
    /// before the store. Anything else is left alone: the rule must not guess.
    private func matchUnconditionalContinuationStore(_ node: FunctionCallExprSyntax) -> APICallFact? {
        guard typeStack.last != nil, !methodStack.isEmpty, closureDepth == 0,
            let callee = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
            Self.continuationMakers.contains(callee),
            let closure = node.trailingClosure ?? node.arguments.last?.expression.as(ClosureExprSyntax.self),
            let before = Self.statementsBefore(node)
        else { return nil }
        let parameter: String
        switch closure.signature?.parameterClause {
        case .simpleInput(let names)?:
            guard names.count == 1, let only = names.first else { return nil }
            parameter = only.name.text
        case .parameterClause(let clause)?:
            guard clause.parameters.count == 1, let only = clause.parameters.first else { return nil }
            parameter = (only.secondName ?? only.firstName).text
        case nil:
            parameter = "$0"
        }
        var seenTokens: [String] = []
        for item in closure.statements {
            if let member = Self.storedMember(item.item, value: parameter),
                !(methodStack.last?.localDeclarations.contains(member) ?? false),
                !seenTokens.contains(member)
            {
                // The method's own statements before the call must decide nothing either.
                guard !Self.decides(before), !Self.mentions(before, member) else { return nil }
                return APICallFact(
                    kind: .continuationStore, position: position(of: item), repeats: nil, targetIsSelf: false,
                    receiverIsSelfMember: true, receiverRootMember: member, closureSelfCapture: nil,
                    consumption: .discarded)
            }
            if Self.decides([Syntax(item)]) { return nil }
            seenTokens += item.tokens(viewMode: .sourceAccurate).compactMap {
                if case .identifier(let name) = $0.tokenKind { name } else { nil }
            }
        }
        return nil
    }

    private static func mentions(_ nodes: [Syntax], _ name: String) -> Bool {
        nodes.contains { node in
            node.tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .identifier(name) }
        }
    }

    /// `member = value` or `self.member = value`, with `value` the bare name.
    private static func storedMember(_ item: CodeBlockItemSyntax.Item, value: String) -> String? {
        let expression = item.as(ExprSyntax.self) ?? item.as(ExpressionStmtSyntax.self)?.expression
        guard let sequence = expression?.as(SequenceExprSyntax.self) else { return nil }
        let elements = Array(sequence.elements)
        guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
            elements[2].as(DeclReferenceExprSyntax.self)?.baseName.text == value
        else { return nil }
        if let reference = elements[0].as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
        if let access = elements[0].as(MemberAccessExprSyntax.self),
            access.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
        {
            return access.declName.baseName.text
        }
        return nil
    }

    /// Whether any of `nodes` holds a condition or a loop: what could keep a
    /// second call out, or run the store more than once.
    private static func decides(_ nodes: [Syntax]) -> Bool {
        final class Finder: SyntaxVisitor {
            var found = false
            override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
                found = true; return .skipChildren
            }
            override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
                found = true; return .skipChildren
            }
            override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
                found = true; return .skipChildren
            }
            override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
                found = true; return .skipChildren
            }
            override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
                found = true; return .skipChildren
            }
            override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
                found = true; return .skipChildren
            }
            override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
                found = true; return .skipChildren
            }
            override func visit(_ node: DoStmtSyntax) -> SyntaxVisitorContinueKind {
                found = true; return .skipChildren
            }
            override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
                if ["??", "&&", "||"].contains(node.operator.text) { found = true }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        for node in nodes { finder.walk(node) }
        return finder.found
    }

    /// The statements of the method before the one that holds `node`, when the
    /// call sits in the method's own body (a `return`, a `try`, an `await`, a
    /// binding of its result), not in a closure or a branch.
    private static func statementsBefore(_ node: FunctionCallExprSyntax) -> [Syntax]? {
        var current = Syntax(node)
        while let parent = current.parent {
            if let item = parent.as(CodeBlockItemSyntax.self), let list = item.parent?.as(CodeBlockItemListSyntax.self),
                let block = list.parent?.as(CodeBlockSyntax.self),
                block.parent?.is(FunctionDeclSyntax.self) == true || block.parent?.is(AccessorDeclSyntax.self) == true
            {
                return list.prefix { $0.id != item.id }.map { Syntax($0) }
            }
            let allowed =
                parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self)
                || parent.is(ReturnStmtSyntax.self) || parent.is(ExpressionStmtSyntax.self)
                || parent.is(CodeBlockItemSyntax.self) || parent.is(InitializerClauseSyntax.self)
                || parent.is(PatternBindingSyntax.self) || parent.is(PatternBindingListSyntax.self)
                || parent.is(VariableDeclSyntax.self)
            guard allowed else { return nil }
            current = parent
        }
        return nil
    }

    /// Same-file inference: calling a member function whose
    /// declared return type is a lifetime token and dropping the result loses
    /// the token exactly like a direct sink discard. Matched by name against
    /// this type's declared functions; locals/params shadow.
    private func matchInferredTokenFactory(_ node: FunctionCallExprSyntax) -> APICallFact? {
        guard let typeName = typeStack.last,
            let functions = memberTable[typeName]?.tokenReturningFunctions,
            !functions.isEmpty
        else { return nil }

        let calleeName: String?
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            calleeName =
                methodStack.last?.localDeclarations.contains(name) == true ? nil : name
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text
            calleeName =
                (base == "self" || base == "Self" || base == typeName)
                ? member.declName.baseName.text : nil
        } else {
            calleeName = nil
        }
        guard let name = calleeName, functions.contains(name) else { return nil }

        return APICallFact(
            kind: .userTokenProducer("the token returned by \(name)()"),
            position: position(of: node),
            repeats: nil,
            targetIsSelf: false,
            closureSelfCapture: nil,
            consumption: classifyConsumption(of: node)
        )
    }

    /// User-KB fallback: `tokenProducer` calls feed the premature-release rules
    /// exactly like built-in token APIs; `sinkWrapper` calls additionally have
    /// their closure argument analyzed for a strong-`self` cycle exactly like
    /// `.sink` (`React.to { self.… }` stored on `self`). The built-in reactive
    /// contracts (`subscribe`, `bind` and `drive` as `disposeBag`,
    /// `start(next:)` as `signalDisposable`) are matched here too, after the
    /// user contracts.
    private func matchUserContract(_ node: FunctionCallExprSyntax) -> APICallFact? {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let callee = member.declName.baseName.text
        // Every member call passes here: return before allocating anything
        // unless a user or built-in contract has this callee name.
        guard Self.builtInCallees.contains(callee) || userContracts.contains(where: { $0.callee == callee }) else {
            return nil
        }
        let labels = node.arguments.compactMap { $0.label?.text }
        for contract in userContracts + Self.builtInContracts where contract.callee == callee {
            if let base = contract.base,
                member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text != base
            {
                continue
            }
            if let required = contract.requiredLabels, !required.allSatisfy(labels.contains) {
                continue
            }
            let name = contract.tokenName ?? "the \(callee) token"
            let (capture, nestedListOnly) = closureSelfCapture(in: node)
            switch contract.template {
            case .tokenProducer:
                return APICallFact(
                    kind: .userTokenProducer(name),
                    position: position(of: node),
                    repeats: nil,
                    targetIsSelf: false,
                    closureSelfCapture: capture,
                    consumption: classifyConsumption(of: node)
                )
            case .sinkWrapper:
                // The wrapper hides the real `.sink`/upstream, so finiteness is
                // genuinely unknown — the cycle fires at warning severity with
                // an honest "completion could not be determined" note.
                return APICallFact(
                    kind: .userSinkWrapper(name),
                    position: position(of: node),
                    repeats: nil,
                    targetIsSelf: false,
                    upstreamFiniteness: .unknown,
                    closureSelfCapture: capture,
                    selfCaptureViaNestedListOnly: nestedListOnly,
                    consumption: classifyConsumption(of: node)
                )
            case .disposeBag, .signalDisposable:
                // Only a Disposable that `self` keeps matters: a reactive
                // subscription is not ended by dropping its Disposable, so
                // nothing else here is a finding. A bag subscription counts
                // only through `.disposed(by: self.<bag>)` or
                // `addDisposableTo(self.<bag>)`: `subscribe`, `bind` and
                // `drive` are common names, and a token that a home-grown bus
                // returns and `self` assigns to a member is not provably a
                // Disposable that keeps the closure.
                let consumption = classifyReactiveConsumption(of: node)
                // `return nil`, not `continue`: a contract whose callee, base
                // and labels match decides the call, also when it decides that
                // there is no finding (`continue` would hand a call that a
                // user contract declares bag-only to a later contract, such as
                // the built-in `signalDisposable` for `start(next:)`).
                if contract.template == .disposeBag, consumption != .chainedStoreIn(memberOfSelf: true) {
                    return nil
                }
                guard consumption.storesIntoSelf else { return nil }
                return APICallFact(
                    kind: .reactiveSubscription(name),
                    position: position(of: node),
                    repeats: nil,
                    targetIsSelf: false,
                    upstreamFiniteness: reactiveFiniteness(of: node, labels: labels),
                    closureSelfCapture: capture,
                    selfCaptureViaNestedListOnly: nestedListOnly,
                    consumption: consumption
                )
            }
        }
        return nil
    }

    /// Reactive subscriptions matched with no configuration: RxSwift's
    /// `subscribe`/`bind`/`drive` and SwiftSignalKit's `start(next:)`. User
    /// contracts are tried first: one whose callee, base and labels match
    /// decides the call, so it can redeclare these names; one whose base or
    /// labels do not match falls through to the built-in.
    private static let builtInContracts: [Configuration.UserContract] = [
        .init(callee: "subscribe", tokenName: "the subscription's Disposable", template: .disposeBag),
        .init(callee: "bind", tokenName: "the subscription's Disposable", template: .disposeBag),
        .init(callee: "drive", tokenName: "the subscription's Disposable", template: .disposeBag),
        .init(
            callee: "start",
            requiredLabels: ["next"],
            tokenName: "the signal's Disposable",
            template: .signalDisposable
        ),
    ]

    private static let builtInCallees = Set(builtInContracts.map(\.callee))

    /// Where a reactive Disposable goes: a chained `.disposed(by: bag)` or
    /// `.addDisposableTo(bag)` stores it in `bag`; an argument of
    /// `self.<disposable>.set(_:)` / `.add(_:)` stores it in that member;
    /// otherwise the ordinary classification (assignment, local, discard).
    private func classifyReactiveConsumption(of node: FunctionCallExprSyntax) -> ResultConsumption {
        if let member = node.parent?.as(MemberAccessExprSyntax.self),
            member.base?.id == node.id,
            let chained = member.parent?.as(FunctionCallExprSyntax.self),
            chained.calledExpression.id == member.id,
            let bag = chained.arguments.first
        {
            let name = member.declName.baseName.text
            if (name == "disposed" && bag.label?.text == "by") || (name == "addDisposableTo" && bag.label == nil) {
                return .chainedStoreIn(memberOfSelf: memberOfSelfName(bag.expression) != nil)
            }
        }
        if let argument = node.parent?.as(LabeledExprSyntax.self),
            argument.label == nil,
            let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
            let setter = call.calledExpression.as(MemberAccessExprSyntax.self),
            ["set", "add"].contains(setter.declName.baseName.text),
            let base = setter.base,
            let holder = memberOfSelfName(base)
        {
            return .storedToSelfMember(holder)
        }
        return classifyConsumption(of: node)
    }

    /// Sources and operators that complete: RxSwift's `Single`, `Completable`
    /// and `Maybe` (and their `as…` conversions), the calls `just(…)`,
    /// `empty()`, `first()` and `take(1)` in the receiver, or a
    /// `subscribe(onSuccess:)` that only a `Single` or `Maybe` offers. A
    /// completed subscription releases its closures, so the cycle is transient.
    private func reactiveFiniteness(
        of node: FunctionCallExprSyntax,
        labels: [String]
    ) -> APICallFact.UpstreamFiniteness {
        if labels.contains("onSuccess") { return .finite }
        guard let receiver = node.calledExpression.as(MemberAccessExprSyntax.self)?.base else {
            return .unknown
        }
        let tokens = receiver.tokens(viewMode: .sourceAccurate).map(\.text)
        for (index, token) in tokens.enumerated() {
            if Self.finiteReactiveMarkers.contains(token) { return .finite }
            if let call = Self.finiteReactiveCalls[token],
                tokens.dropFirst(index + 1).prefix(call.count).elementsEqual(call)
            {
                return .finite
            }
        }
        return .unknown
    }

    private static let finiteReactiveMarkers: Set<String> = [
        "Single", "Completable", "Maybe", "asSingle", "asCompletable", "asMaybe",
    ]

    /// Finite calls, matched with the tokens that follow the name: a property
    /// named `first` (`users.first?.events`) is not the operator `first()`.
    private static let finiteReactiveCalls: [String: [String]] = [
        "just": ["("], "empty": ["(", ")"], "first": ["(", ")"], "take": ["(", "1", ")"],
    ]

    /// Strongest `self` capture across every closure a wrapper call carries —
    /// trailing, additional-trailing, and closure-literal arguments — plus
    /// bound-method values (`React.to(.x, with: self.handle)`). Mirrors the
    /// `.sink` matcher: any bare `self` beats nested-list-only evidence.
    private func closureSelfCapture(
        in node: FunctionCallExprSyntax
    ) -> (SelfCaptureKind?, Bool) {
        func rank(_ kind: SelfCaptureKind?) -> Int {
            switch kind {
            case nil, .some(.none): 0
            case .some(.weak): 1
            case .some(.unowned): 2
            case .some(.strong): 3
            }
        }
        var closures: [ClosureExprSyntax] = []
        if let trailing = node.trailingClosure { closures.append(trailing) }
        for additional in node.additionalTrailingClosures { closures.append(additional.closure) }
        for argument in node.arguments {
            if let closure = argument.expression.as(ClosureExprSyntax.self) {
                closures.append(closure)
            }
        }
        var capture: SelfCaptureKind?
        var nestedListOnly = false
        for closure in closures {
            let analysis = ClosureCaptureAnalysis.analyze(
                closure: closure,
                memberNames: currentMemberNames,
                allowImplicitSelf: false
            )
            let newRank = rank(analysis.selfCapture)
            if newRank > rank(capture) {
                capture = analysis.selfCapture
                nestedListOnly = analysis.strongViaNestedCaptureOnly
            } else if newRank == 3 {
                nestedListOnly = nestedListOnly && analysis.strongViaNestedCaptureOnly
            }
        }
        // A bound method / self-referencing local passed as the action is a
        // strong capture with no capture-list syntax available.
        for argument in node.arguments where !argument.expression.is(ClosureExprSyntax.self) {
            if strongCaptureEquivalent(argument.expression) {
                return (.strong(implicit: false), false)
            }
        }
        return (capture, nestedListOnly)
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
        // ALL attached closures: trailing, additional-trailing, and labeled.
        // `sink(receiveCompletion:receiveValue:)` can hide its strong self in
        // either closure — analyzing just one was a false-negative source.
        func attachedClosures(labels closureLabels: [String]) -> [ClosureExprSyntax] {
            var closures: [ClosureExprSyntax] = []
            if let trailing = node.trailingClosure { closures.append(trailing) }
            for additional in node.additionalTrailingClosures {
                closures.append(additional.closure)
            }
            for label in closureLabels {
                if let closure = argument(label)?.as(ClosureExprSyntax.self) {
                    closures.append(closure)
                }
            }
            return closures
        }

        let kind: APICallFact.Kind
        var targetIsSelf = false
        var receiverIsSelfMember = false
        var receiverRootMember: String?
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
                closureLabels = ["receiveValue", "receiveCompletion"]
            case "assign" where labels.contains("to") && labels.contains("on"):
                kind = .combineAssignOn
                targetIsSelf = isSelf(argument("on"))
            case "observe" where node.arguments.first?.expression.is(KeyPathExprSyntax.self) == true:
                kind = .kvoObserve
                closureLabels = ["changeHandler"]
            case "addPeriodicTimeObserver":
                kind = .periodicTimeObserver
                closureLabels = ["using"]
            case _
            where ["add", "addScriptMessageHandler"].contains(callee) && labels.contains("name")
                && Self.isUserContentController(member.base):
                kind = .scriptMessageHandlerAdd
                if let handler = node.arguments.first, handler.label == nil {
                    targetIsSelf = isSelf(handler.expression)
                }
                receiverRootMember = rootMemberOfSelf(member.base)
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
            labels.contains("target")
        {
            kind = .displayLinkTarget
            targetIsSelf = isSelf(argument("target"))
        } else if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
            reference.baseName.text == "URLSession",
            labels.contains("configuration"),
            labels.contains("delegate")
        {
            kind = .urlSessionWithDelegate
            targetIsSelf = isSelf(argument("delegate"))
        } else {
            return nil
        }

        // Strongest capture across every attached closure wins; the
        // nested-list-only flag survives only if EVERY strong capture is
        // nested-list evidence (any bare self makes the plain message right).
        func rank(_ kind: SelfCaptureKind?) -> Int {
            switch kind {
            case nil, .some(.none): 0
            case .some(.weak): 1
            case .some(.unowned): 2
            case .some(.strong): 3
            }
        }
        var closureCapture: SelfCaptureKind?
        var nestedListOnly = false
        for closure in attachedClosures(labels: closureLabels) {
            let analysis = ClosureCaptureAnalysis.analyze(
                closure: closure,
                memberNames: currentMemberNames,
                allowImplicitSelf: false
            )
            let newRank = rank(analysis.selfCapture)
            if newRank > rank(closureCapture) {
                closureCapture = analysis.selfCapture
                nestedListOnly = analysis.strongViaNestedCaptureOnly
            } else if newRank == 3 {
                nestedListOnly = nestedListOnly && analysis.strongViaNestedCaptureOnly
            }
        }
        // `sink(receiveValue: self.handle)` — a bound method value is a strong
        // capture, same pipeline as a strong-self closure (checked alongside
        // closures: arguments can mix both).
        for label in closureLabels {
            if let expr = argument(label), !expr.is(ClosureExprSyntax.self),
                strongCaptureEquivalent(expr)
            {
                closureCapture = .strong(implicit: false)
                nestedListOnly = false
                break
            }
        }

        var finiteness = APICallFact.UpstreamFiniteness.unknown
        var rootMember: String?
        if kind == .combineSink || kind == .combineAssignOn {
            (finiteness, rootMember) = classifyUpstream(of: node)
        }

        return APICallFact(
            kind: kind,
            position: position(of: node),
            repeats: repeatsLiteral(),
            targetIsSelf: targetIsSelf,
            receiverIsSelfMember: receiverIsSelfMember,
            receiverRootMember: receiverRootMember,
            upstreamFiniteness: finiteness,
            upstreamRootMember: rootMember,
            closureSelfCapture: closureCapture,
            selfCaptureViaNestedListOnly: nestedListOnly,
            consumption: classifyConsumption(of: node)
        )
    }

    /// `webView.configuration.userContentController`, or any receiver whose
    /// last name component ends in `ContentController` (a local or property
    /// holding a `WKUserContentController`).
    private static func isUserContentController(_ base: ExprSyntax?) -> Bool {
        let name: String? =
            base?.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            ?? base?.as(DeclReferenceExprSyntax.self)?.baseName.text
        guard let name else { return false }
        return name.lowercased().hasSuffix("contentcontroller")
    }

    /// The stored member of `self` that a receiver chain starts from, through
    /// member accesses, `?` and `!`: `webView` in
    /// `self.webView.configuration.userContentController`. Nil when the chain
    /// starts at a local, a parameter or anything else.
    private func rootMemberOfSelf(_ base: ExprSyntax?) -> String? {
        var current = base
        while let expr = current {
            if let name = memberOfSelfName(expr) { return name }
            if let member = expr.as(MemberAccessExprSyntax.self) {
                current = member.base
            } else if let optional = expr.as(OptionalChainingExprSyntax.self) {
                current = optional.expression
            } else if let forced = expr.as(ForceUnwrapExprSyntax.self) {
                current = forced.expression
            } else {
                return nil
            }
        }
        return nil
    }

    /// Operators that force completion regardless of what feeds them.
    private static let finiteChainMarkers: Set<String> = [
        "first", "prefix", "output", "dataTaskPublisher", "Just", "Empty", "Fail",
        "Future", "Record", "Deferred",
    ]
    /// Sources that never complete while their owner lives.
    private static let infiniteChainMarkers: Set<String> = ["publish"]
    static let subjectTypeNames: Set<String> = ["PassthroughSubject", "CurrentValueSubject"]

    /// Syntactic classification of a sink/assign upstream: walks the receiver
    /// chain collecting operator and source names. Finite markers win (a
    /// `.first()` completes even a subject pipeline); `$projected` values and
    /// `Timer.publish` are infinite; a bare chain-root member is reported for
    /// per-type resolution against subject-backed properties in `finish()`.
    private func classifyUpstream(
        of node: FunctionCallExprSyntax
    ) -> (APICallFact.UpstreamFiniteness, String?) {
        var names: [String] = []
        var sawProjected = false
        var rootMember: String?

        var current = node.calledExpression.as(MemberAccessExprSyntax.self)?.base
        while let expr = current {
            if let call = expr.as(FunctionCallExprSyntax.self) {
                current = call.calledExpression
                continue
            }
            if let tryExpr = expr.as(TryExprSyntax.self) {
                current = tryExpr.expression
                continue
            }
            if let awaitExpr = expr.as(AwaitExprSyntax.self) {
                current = awaitExpr.expression
                continue
            }
            if let generic = expr.as(GenericSpecializationExprSyntax.self) {
                current = generic.expression
                continue
            }
            if let member = expr.as(MemberAccessExprSyntax.self) {
                let name = member.declName.baseName.text
                names.append(name)
                if name.hasPrefix("$") { sawProjected = true }
                if member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self",
                    currentMemberNames.contains(name)
                {
                    rootMember = name
                }
                current = member.base
                continue
            }
            if let reference = expr.as(DeclReferenceExprSyntax.self) {
                let name = reference.baseName.text
                names.append(name)
                if name.hasPrefix("$") { sawProjected = true }
                if currentMemberNames.contains(name) { rootMember = name }
                current = nil
                continue
            }
            current = nil
        }

        if names.contains(where: { Self.finiteChainMarkers.contains($0) }) {
            return (.finite, rootMember)
        }
        if sawProjected { return (.infinite, rootMember) }
        if names.contains(where: { Self.infiniteChainMarkers.contains($0) }) {
            return (.infinite, rootMember)
        }
        if names.contains(where: { Self.subjectTypeNames.contains($0) }) {
            return (.infinite, rootMember)
        }
        if names.contains("publisher"), names.contains("NotificationCenter") {
            return (.infinite, rootMember)
        }
        return (.unknown, rootMember)
    }

    private func matchTaskSpawn(_ node: FunctionCallExprSyntax) -> TaskSpawnFact? {
        let isTask: Bool
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            isTask = reference.baseName.text == "Task"
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Task",
            member.declName.baseName.text == "detached"
        {
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
            consumption: classifyConsumption(of: node),
            bodyAwaits: analysis.hasAwait
        )
    }

    private func recordReleaseSiteIfAny(_ node: FunctionCallExprSyntax) {
        let kind: ReleaseSite.Kind
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            let memberKind = ReleaseSite.Kind(calleeName: member.declName.baseName.text)
        {
            kind = memberKind
        } else if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
            ReleaseSite.Kind(calleeName: reference.baseName.text) == .zeroBytes
        {
            // `memset(buffer, 0, count)` is a free function. Only the
            // zeroing kind is read from bare calls: a bare `cancel()` is a
            // method of self, not a release of a stored handle.
            kind = .zeroBytes
        } else {
            return
        }
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
            let base = member.base
        else { return }
        let collection: String
        let ownedChild: String?
        if let name = memberOfSelfName(base) {
            collection = name
            ownedChild = nil
        } else if let target = ownedChildTarget(base) {
            collection = "\(target.child).\(target.member)"
            ownedChild = target.child
        } else {
            return
        }

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
                selfCapture: analysis.selfCapture,
                ownedChild: ownedChild
            )
        )
    }

    /// `self.toolbar.onTap` / `toolbar?.onTap` / `toolbar!.onTap` → ("toolbar",
    /// "onTap") when `toolbar` is a member of `self` (not a shadowing local).
    /// Exactly one level: `self.a.b.c` is not matched.
    private func ownedChildTarget(_ expr: some ExprSyntaxProtocol) -> (child: String, member: String)? {
        guard let access = ExprSyntax(expr).as(MemberAccessExprSyntax.self), var base = access.base else {
            return nil
        }
        if let optional = base.as(OptionalChainingExprSyntax.self) {
            base = optional.expression
        } else if let forced = base.as(ForceUnwrapExprSyntax.self) {
            base = forced.expression
        }
        guard let child = memberOfSelfName(base) else { return nil }
        return (child, access.declName.baseName.text)
    }

    /// `self.method`, a bare member-method name, or a self-referencing local
    /// function used as a VALUE — a strong capture of `self` with no
    /// capture-list syntax available.
    private func strongCaptureEquivalent(_ expr: ExprSyntax) -> Bool {
        let expr = unwrapped(expr)
        if let member = expr.as(MemberAccessExprSyntax.self),
            member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self",
            currentFunctionMembers.contains(member.declName.baseName.text)
        {
            return true
        }
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            // Local funcs first: they live in `localDeclarations` too, but a
            // self-referencing one used as a value IS a strong capture.
            if methodStack.last?.selfReferencingLocalFunctions.contains(name) == true {
                return true
            }
            // A parameter or local shadowing a method name wins the lookup:
            // `defaultColor = color` inside `setDefaultColor(_ color: Color)`
            // stores the parameter, not a bound `self.color` method value.
            if methodStack.last?.localDeclarations.contains(name) == true { return false }
            if currentFunctionMembers.contains(name) { return true }
        }
        return false
    }

    private var currentFunctionMembers: Set<String> {
        guard let typeName = typeStack.last else { return [] }
        return memberTable[typeName]?.functionMembers ?? []
    }

    /// `[weak self]` whose body never touches `self` is capture-list noise —
    /// collected for the opt-in dead-weak-capture rule. Also tracks closure
    /// nesting depth for `store(in:)` local-lifetime classification.
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        closureDepth += 1
        if let items = node.signature?.capture?.items,
            items.contains(where: {
                $0.name.text == "self" && $0.initializer == nil
                    && $0.specifier?.specifier.text == "weak"
            }),
            !ClosureCaptureAnalysis.referencesSelfExplicitly(node.statements)
        {
            collected[typeStack.last ?? Self.fileScopeKey, default: CollectedFacts()]
                .deadWeakCaptures.append(position(of: node))
        }
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) { closureDepth -= 1 }

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
                    argument.label?.text == "in"
                {
                    return classifyStoreInTarget(argument.expression, tokenCall: call)
                }
                current = Syntax(chained)
                continue
            }
            // `a = expr` parses as SequenceExpr(ExprList[a, =, expr]): the call's
            // parent is the element list, and the sequence sits one level up.
            if let list = parent.as(ExprListSyntax.self),
                let sequence = list.parent?.as(SequenceExprSyntax.self)
            {
                return classifyAssignment(sequence: sequence, rhsID: current.id)
            }
            if let sequence = parent.as(SequenceExprSyntax.self) {
                return classifyAssignment(sequence: sequence, rhsID: current.id)
            }
            if let initializer = parent.as(InitializerClauseSyntax.self),
                initializer.value.id == current.id
            {
                return classifyBinding(initializer)
            }
            if parent.is(ReturnStmtSyntax.self) { return .returned }
            if let item = parent.as(CodeBlockItemSyntax.self) {
                return classifyBareStatement(item)
            }
            return .other
        }
        return .other
    }

    /// `store(in:)` ownership. `self.x` and unshadowed members
    /// (including protocol requirements) are instance storage. A bare local —
    /// or a member chain ROOTED at a local (`holder.bag`) — dies at scope end
    /// when the store runs at the local's own closure depth or only inside
    /// known non-escaping closures (`forEach`, immediately-applied); through
    /// an escaping capture the claim shifts to lifetime-tied-to-the-closure
    /// instead of going silent. Parameter-rooted chains and out-of-file
    /// superclass members stay silent: the probable truth is durable
    /// instance storage.
    private func classifyStoreInTarget(
        _ target: ExprSyntax,
        tokenCall: FunctionCallExprSyntax
    ) -> ResultConsumption {
        guard let stored = target.as(InOutExprSyntax.self)?.expression else { return .other }
        if memberOfSelfName(stored) != nil {
            return .chainedStoreIn(memberOfSelf: true)
        }
        if let reference = stored.as(DeclReferenceExprSyntax.self) {
            return classifyLocalStore(reference.baseName.text, tokenCall: tokenCall)
        }
        if let root = chainRootName(of: stored),
            methodStack.last?.localBindingDepths[root] != nil
        {
            return classifyLocalStore(root, tokenCall: tokenCall)
        }
        return .other
    }

    private func classifyLocalStore(
        _ name: String,
        tokenCall: FunctionCallExprSyntax
    ) -> ResultConsumption {
        guard let declarationDepth = methodStack.last?.localBindingDepths[name] else {
            return .other
        }
        let delta = closureDepth - declarationDepth
        if delta <= 0 { return .chainedStoreIn(memberOfSelf: false) }
        let hops = enclosingClosures(of: Syntax(tokenCall), count: delta)
        if hops.count == delta, hops.allSatisfy(Self.isNonEscapingContext) {
            return .chainedStoreIn(memberOfSelf: false)
        }
        return .chainedStoreInCapturedLocal(name)
    }

    /// `context.coordinator.bag` → "context" (nil when the root is not a
    /// plain identifier).
    private func chainRootName(of expr: ExprSyntax) -> String? {
        var current = expr
        while let member = current.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return nil }
            current = base
        }
        return current.as(DeclReferenceExprSyntax.self)?.baseName.text
    }

    private func enclosingClosures(of node: Syntax, count: Int) -> [ClosureExprSyntax] {
        var closures: [ClosureExprSyntax] = []
        var current: Syntax? = node.parent
        while let some = current, closures.count < count {
            if let closure = some.as(ClosureExprSyntax.self) {
                closures.append(closure)
            }
            current = some.parent
        }
        return closures
    }

    /// Stdlib sequence/scope functions whose closures are documented
    /// non-escaping — a store through them still dies with the enclosing scope.
    private static let nonEscapingHOFs: Set<String> = [
        "forEach", "map", "compactMap", "flatMap", "filter", "reduce", "sorted",
        "sort", "contains", "first", "allSatisfy", "min", "max",
        "withExtendedLifetime",
    ]

    /// Trailing/labeled closure of a known non-escaping HOF, or an
    /// immediately-applied closure literal (`({ … })()`).
    private static func isNonEscapingContext(_ closure: ClosureExprSyntax) -> Bool {
        guard let parent = closure.parent else { return false }
        if let call = parent.as(FunctionCallExprSyntax.self) {
            var callee = call.calledExpression
            if let tuple = callee.as(TupleExprSyntax.self),
                tuple.elements.count == 1,
                let inner = tuple.elements.first?.expression
            {
                callee = inner
            }
            if callee.id == closure.id { return true }
            if call.trailingClosure?.id == closure.id,
                let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                nonEscapingHOFs.contains(member.declName.baseName.text)
            {
                return true
            }
        }
        if let labeled = parent.as(LabeledExprSyntax.self),
            let list = labeled.parent?.as(LabeledExprListSyntax.self),
            let call = list.parent?.as(FunctionCallExprSyntax.self),
            let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            nonEscapingHOFs.contains(member.declName.baseName.text)
        {
            return true
        }
        return false
    }

    /// A bare expression statement is a discard — unless it is the *only*
    /// statement of a value-returning body, where SE-0255 makes it the implicit
    /// return value (token factories: `func to(…) -> AnyCancellable { …sink }`).
    private func classifyBareStatement(_ item: CodeBlockItemSyntax) -> ResultConsumption {
        guard
            let list = item.parent?.as(CodeBlockItemListSyntax.self),
            list.count == 1,
            let owner = list.parent
        else { return .discarded }
        // `var token: T { …sink }` — shorthand getter bodies hang directly
        // off the accessor block, with no CodeBlock wrapper.
        if owner.is(AccessorBlockSyntax.self) { return .returned }
        guard let blockOwner = owner.as(CodeBlockSyntax.self)?.parent else { return .discarded }
        if let function = blockOwner.as(FunctionDeclSyntax.self),
            function.signature.returnClause != nil
        {
            return .returned
        }
        if let accessor = blockOwner.as(AccessorDeclSyntax.self),
            accessor.accessorSpecifier.tokenKind == .keyword(.get)
        {
            return .returned
        }
        // Closures stay discarded: without type information their context
        // (Void or value-returning) is unknowable, and the common
        // `queue.async { publisher.sink { … } }` really does drop the token.
        return .discarded
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

    /// `self.x` → "x"; bare `x` when `x` is an *unshadowed* member of the
    /// enclosing type → "x".
    private func memberOfSelfName(_ expr: some ExprSyntaxProtocol) -> String? {
        if let member = ExprSyntax(expr).as(MemberAccessExprSyntax.self),
            member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
        {
            return member.declName.baseName.text
        }
        if let reference = ExprSyntax(expr).as(DeclReferenceExprSyntax.self),
            currentMemberNames.contains(reference.baseName.text),
            methodStack.last?.localDeclarations.contains(reference.baseName.text) != true
        {
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
