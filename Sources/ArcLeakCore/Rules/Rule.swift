/// A memory rule: a pure function from one type's facts to findings.
///
/// Rules never see syntax trees — only `TypeFacts` — which keeps them trivially
/// testable and keeps tree lifetime confined to extraction.
protocol Rule: Sendable {
    /// Rule ids this rule can emit (used for config gating).
    static var emits: [RuleID] { get }
    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding]
}

/// A rule that needs the whole analyzed corpus at once (cross-file analysis,
/// e.g. the ownership graph). Runs after all per-file extraction completes.
protocol CorpusRule: Sendable {
    static var emits: [RuleID] { get }
    static func check(corpus: [FileFacts], configuration: Configuration) -> [Finding]
}

/// Applies every enabled rule to every type in a file.
public enum RuleEngine {
    private static let rules: [any Rule.Type] = [
        StoredClosureStrongSelfRule.self,
        TimerRetainsSelfRule.self,
        NotificationObserverLeakRule.self,
        CombineSinkSelfCycleRule.self,
        CombineAssignSelfCycleRule.self,
        TaskNonterminatingSelfRule.self,
        UnstoredLifetimeTokenRule.self,
        URLSessionDelegateLeakRule.self,
        DispatchSourceCycleRule.self,
        UnownedOutlivesOwnerRule.self,
        DeadWeakCaptureRule.self,
        DelegateStrongPropertyRule.self,
    ]

    private static let corpusRules: [any CorpusRule.Type] = [
        MutualStrongPropertiesRule.self
    ]

    public static func check(file: FileFacts, configuration: Configuration) -> [Finding] {
        var findings: [Finding] = []
        for type in file.types {
            for rule in rules where rule.emits.contains(where: configuration.isEnabled) {
                findings.append(
                    contentsOf: rule.check(type: type, path: file.path, configuration: configuration)
                        .filter { configuration.isEnabled($0.rule) }
                )
            }
        }
        return findings.sorted()
    }

    /// Cross-file rules over the whole corpus. `corpus` must be pre-sorted by
    /// path for deterministic output (the Analyzer guarantees this).
    public static func checkCorpus(corpus: [FileFacts], configuration: Configuration) -> [Finding] {
        var findings: [Finding] = []
        for rule in corpusRules where rule.emits.contains(where: configuration.isEnabled) {
            findings.append(
                contentsOf: rule.check(corpus: corpus, configuration: configuration)
                    .filter { configuration.isEnabled($0.rule) }
            )
        }
        return findings.sorted()
    }
}
