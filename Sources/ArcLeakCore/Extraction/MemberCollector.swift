import SwiftIfConfig
import SwiftSyntax

/// First pass over a file: builds the per-type member tables the extraction
/// pass needs (reference-ness, member names). Same-file extensions merge into
/// their nominal type; extensions of externally declared types stay with
/// `isReferenceType == nil` so cycle rules skip them instead of guessing.
final class MemberCollector: SyntaxVisitor {
    struct Entry {
        var isReferenceType: Bool?
        var members: Set<String> = []
        /// Superclass + conformance names from the inheritance clause (classes/
        /// actors) — powers ownership heuristics (XCTestCase, app delegates).
        var inheritedTypes: Set<String> = []
    }

    private(set) var table: [String: Entry] = [:]
    private var typeStack: [String] = []
    private let buildConfiguration: StaticBuildConfiguration

    init(buildConfiguration: StaticBuildConfiguration) {
        self.buildConfiguration = buildConfiguration
        super.init(viewMode: .sourceAccurate)
    }

    /// Facts come only from the *active* `#if` clause — matching what a compile
    /// under this configuration would see.
    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        if let clause = node.activeClause(in: buildConfiguration).clause,
            let elements = clause.elements
        {
            walk(elements)
        }
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: node.name.text, isReference: true)
        addInheritedTypes(node.inheritanceClause, to: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: node.name.text, isReference: true)
        addInheritedTypes(node.inheritanceClause, to: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: node.name.text, isReference: false)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: node.name.text, isReference: false)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: Self.extendedTypeName(node.extendedType), isReference: nil)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if isDirectTypeMember(node) {
            for binding in node.bindings {
                if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                    addMember(identifier.identifier.text)
                }
            }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if isDirectTypeMember(node) {
            addMember(node.name.text)
        }
        return .visitChildren
    }

    static func extendedTypeName(_ type: TypeSyntax) -> String {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return member.name.text
        }
        return type.trimmedDescription
    }

    private func push(name: String, isReference: Bool?) {
        typeStack.append(name)
        var entry = table[name] ?? Entry(isReferenceType: nil)
        if let isReference {
            entry.isReferenceType = isReference
        }
        table[name] = entry
    }

    private func addMember(_ name: String) {
        guard let typeName = typeStack.last else { return }
        table[typeName, default: Entry(isReferenceType: nil)].members.insert(name)
    }

    private func addInheritedTypes(_ clause: InheritanceClauseSyntax?, to typeName: String) {
        guard let clause else { return }
        for inherited in clause.inheritedTypes {
            table[typeName, default: Entry(isReferenceType: nil)]
                .inheritedTypes.insert(Self.extendedTypeName(inherited.type))
        }
    }

    private func isDirectTypeMember(_ node: some SyntaxProtocol) -> Bool {
        !typeStack.isEmpty && node.parent?.is(MemberBlockItemSyntax.self) == true
    }
}
