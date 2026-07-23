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
        /// Member *functions* only — a `self.method` reference used as a value
        /// is a strong capture of `self` with no capture-list syntax available.
        var functionMembers: Set<String> = []
        /// Superclass + conformance names from the inheritance clause (classes/
        /// actors) — powers ownership heuristics (XCTestCase, app delegates).
        var inheritedTypes: Set<String> = []
        /// Attribute names on the type declaration itself (`Model`,
        /// `Observable`) — macro-managed storage changes ownership semantics.
        var typeAttributes: Set<String> = []
        /// Member functions whose declared return type is a lifetime token
        /// (`AnyCancellable`, `NSKeyValueObservation`): discarding their result
        /// at a call site loses the token exactly like a direct sink discard.
        var tokenReturningFunctions: Set<String> = []
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
        addTypeAttributes(node.attributes, to: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: node.name.text, isReference: true)
        addInheritedTypes(node.inheritanceClause, to: node.name.text)
        addTypeAttributes(node.attributes, to: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: node.name.text, isReference: false)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    /// Protocol requirements are members too: a `{ get set }` var used from a
    /// protocol-extension method (`store(in: &webSocketCancellables)`) resolves
    /// to instance storage, not a local.
    /// `isReferenceType` stays nil — requirement-level facts never prove
    /// reference-ness, so cycle rules keep skipping protocol scopes.
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: node.name.text, isReference: nil)
        addInheritedTypes(node.inheritanceClause, to: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) { typeStack.removeLast() }

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
            // static/class methods stay out of `functionMembers`: from instance
            // context a bare or `self.`-qualified name can never resolve to
            // them, so matching them would fabricate bound-method self
            // captures.
            let isStatic = node.modifiers.contains {
                $0.name.text == "static" || $0.name.text == "class"
            }
            if !isStatic, let typeName = currentTypeName {
                table[typeName, default: Entry(isReferenceType: nil)]
                    .functionMembers.insert(node.name.text)
            }
            // Statics included: `Self.make()`/`TypeName.make()` discards lose
            // the token the same way. Matched by name only — overloads are
            // not distinguished.
            if let typeName = currentTypeName,
                let returnType = node.signature.returnClause?.type,
                let nominal = Self.nominalName(returnType),
                Self.tokenTypeNames.contains(nominal)
            {
                table[typeName, default: Entry(isReferenceType: nil)]
                    .tokenReturningFunctions.insert(node.name.text)
            }
        }
        return .visitChildren
    }

    static let tokenTypeNames: Set<String> = ["AnyCancellable", "NSKeyValueObservation"]

    /// Unwraps optionals/attributes to the nominal return type name.
    private static func nominalName(_ type: TypeSyntax) -> String? {
        var current = type
        while true {
            if let optional = current.as(OptionalTypeSyntax.self) {
                current = optional.wrappedType
            } else if let attributed = current.as(AttributedTypeSyntax.self) {
                current = attributed.baseType
            } else {
                break
            }
        }
        return current.as(IdentifierTypeSyntax.self)?.name.text
    }

    private var currentTypeName: String? { typeStack.last }

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

    private func addTypeAttributes(_ attributes: AttributeListSyntax, to typeName: String) {
        for attribute in attributes {
            guard
                let name = attribute.as(AttributeSyntax.self)?
                    .attributeName.as(IdentifierTypeSyntax.self)?.name.text
            else { continue }
            table[typeName, default: Entry(isReferenceType: nil)].typeAttributes.insert(name)
        }
    }

    private func isDirectTypeMember(_ node: some SyntaxProtocol) -> Bool {
        !typeStack.isEmpty && node.parent?.is(MemberBlockItemSyntax.self) == true
    }
}
