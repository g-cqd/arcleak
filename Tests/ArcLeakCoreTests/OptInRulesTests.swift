import ArcLeakCore
import Testing

/// The two opt-in rules: disabled by default, precise when enabled.
@Suite struct OptInRulesTests {
    private let deadWeakSource = """
        final class Noisy {
            var onDone: (() -> Void)?
            func arm(completion: @escaping () -> Void) {
                onDone = { [weak self] in completion() }
            }
        }
        """

    private let delegateSource = """
        final class Sheet {
            var delegate: SheetDelegate?
            weak var dataSource: SheetDataSource?
        }
        final class SheetDelegate {}
        final class SheetDataSource {}
        """

    @Test("Both rules are silent by default")
    func disabledByDefault() {
        #expect(Analyzer().analyze(source: deadWeakSource, path: "a.swift").findings.isEmpty)
        // delegateSource still yields the corpus cycle? No back-reference exists,
        // so default rules stay silent too.
        #expect(Analyzer().analyze(source: delegateSource, path: "b.swift").findings.isEmpty)
    }

    @Test("dead-weak-capture flags unused [weak self], not SE-0365 bodies")
    func deadWeakWhenEnabled() {
        let configuration = Configuration(
            rules: ["dead-weak-capture": .init(enabled: true)]
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: deadWeakSource, path: "a.swift").findings
        #expect(findings.map(\.rule) == [.deadWeakCapture])

        let used = """
            final class Fine {
                var onDone: (() -> Void)?
                func arm() {
                    onDone = { [weak self] in
                        guard let self else { return }
                        touch()
                    }
                }
                func touch() {}
            }
            """
        let clean = Analyzer(configuration: configuration)
            .analyze(source: used, path: "b.swift").findings
        #expect(clean.isEmpty)
    }

    @Test("delegate-strong-property flags strong delegates only")
    func delegateWhenEnabled() {
        let configuration = Configuration(
            rules: ["delegate-strong-property": .init(enabled: true)]
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: delegateSource, path: "b.swift").findings
        #expect(findings.map(\.rule) == [.delegateStrongProperty])
        #expect(findings.first?.message.contains("'delegate'") == true)
    }
}
