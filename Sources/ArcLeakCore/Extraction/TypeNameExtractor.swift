import SwiftSyntax

/// Collects the nominal type names referenced by a type annotation, unwrapping
/// sugar iteratively (worklist, no recursion): `Optional`, `[T]`, `[K: V]`,
/// generic arguments, `any`/`some` constraints, attributed types, tuples.
///
/// Function types are deliberately dropped: closure-typed storage is modeled by
/// the stored-closure capture facts, not by type edges.
enum TypeNameExtractor {
    static func nominalNames(in type: TypeSyntax) -> [String] {
        var names: [String] = []
        var worklist: [TypeSyntax] = [type]

        while let current = worklist.popLast() {
            if let identifier = current.as(IdentifierTypeSyntax.self) {
                names.append(identifier.name.text)
                if let arguments = identifier.genericArgumentClause?.arguments {
                    for argument in arguments {
                        if let argumentType = argument.argument.as(TypeSyntax.self) {
                            worklist.append(argumentType)
                        }
                    }
                }
            } else if let member = current.as(MemberTypeSyntax.self) {
                names.append(member.name.text)
                if let arguments = member.genericArgumentClause?.arguments {
                    for argument in arguments {
                        if let argumentType = argument.argument.as(TypeSyntax.self) {
                            worklist.append(argumentType)
                        }
                    }
                }
            } else if let optional = current.as(OptionalTypeSyntax.self) {
                worklist.append(optional.wrappedType)
            } else if let unwrapped = current.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
                worklist.append(unwrapped.wrappedType)
            } else if let array = current.as(ArrayTypeSyntax.self) {
                worklist.append(array.element)
            } else if let dictionary = current.as(DictionaryTypeSyntax.self) {
                worklist.append(dictionary.key)
                worklist.append(dictionary.value)
            } else if let attributed = current.as(AttributedTypeSyntax.self) {
                worklist.append(attributed.baseType)
            } else if let someOrAny = current.as(SomeOrAnyTypeSyntax.self) {
                worklist.append(someOrAny.constraint)
            } else if let tuple = current.as(TupleTypeSyntax.self) {
                for element in tuple.elements {
                    worklist.append(element.type)
                }
            }
            // FunctionTypeSyntax and everything else: no nominal edge.
        }
        return names
    }
}
