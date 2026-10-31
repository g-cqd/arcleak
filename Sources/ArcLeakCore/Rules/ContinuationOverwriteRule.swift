/// `member = continuation` in a `with…Continuation` closure, with nothing
/// before it that checks, resumes or clears the member and no condition that
/// could keep a second call out (the extraction records only those). A second
/// call before the first resume replaces the first caller's continuation, which
/// then never resumes. Reported when the member is a stored property of the
/// type: a computed one's setter decides what a store does.
struct ContinuationOverwriteRule: Rule {
    static let emits: [RuleID] = [.continuationOverwrite]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        let stored = Set(type.storedProperties.map(\.name))
        return type.apiCalls.compactMap { call in
            guard call.kind == .continuationStore, let member = call.receiverRootMember, stored.contains(member)
            else { return nil }
            return Finding(
                rule: .continuationOverwrite,
                severity: configuration.severity(for: .continuationOverwrite),
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "continuation stored over '\(member)' with nothing that checks or resumes the one it may hold — a second call before the first resumes leaves that caller suspended forever",
                note:
                    "guard \(member) == nil else { continuation.resume(throwing: …); return }, or resume the old one first, or keep each caller's continuation under its own key"
            )
        }
    }
}
