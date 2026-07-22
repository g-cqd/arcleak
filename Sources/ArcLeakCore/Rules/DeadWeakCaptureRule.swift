/// Opt-in tidiness: `[weak self]` whose body never references `self`. The
/// capture does nothing and buries the capture lists that matter. SE-0365
/// bodies (`guard let self`) count as uses, so correctly-broken cycles are
/// never flagged.
struct DeadWeakCaptureRule: Rule {
    static let emits: [RuleID] = [.deadWeakCapture]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        type.deadWeakCaptures.map { position in
            Finding(
                rule: .deadWeakCapture,
                severity: configuration.severity(for: .deadWeakCapture),
                path: path,
                line: position.line,
                column: position.column,
                message: "[weak self] is dead — the closure body never uses self",
                note: "delete the capture-list entry; unused weak captures are noise that hides the real ones"
            )
        }
    }
}
