import ArcLeakCore
import Testing

/// The opt-in rules: disabled by default, precise when enabled.
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

    private let vaultSource = """
        import Foundation

        final class KeyVault {
            var key = Data(count: 32)
            var onChange: (() -> Void)?

            func arm() {
                onChange = { self.rotate() }
            }

            func rotate() {}

            deinit {
                key.resetBytes(in: 0..<key.count)
            }
        }

        final class Session {
            var handle: FileHandle?

            deinit {
                handle?.closeFile()
            }
        }
        """

    @Test("sec-cleanup-in-unreachable-deinit is silent by default")
    func secCleanupDisabledByDefault() {
        let findings = Analyzer().analyze(source: vaultSource, path: "Vault.swift").findings
        #expect(findings.map(\.rule) == [.storedClosureStrongSelf])
    }

    @Test("sec-cleanup-in-unreachable-deinit notes a deinit cleanup that a reported cycle makes unreachable")
    func secCleanupWhenEnabled() throws {
        let configuration = Configuration(
            rules: ["sec-cleanup-in-unreachable-deinit": .init(enabled: true)]
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: vaultSource, path: "Vault.swift").findings
        // Only KeyVault: Session closes its handle in deinit but no cycle keeps it alive.
        #expect(findings.map(\.rule) == [.secCleanupInUnreachableDeinit, .storedClosureStrongSelf])
        let cleanup = try #require(findings.first { $0.rule == .secCleanupInUnreachableDeinit })
        #expect(cleanup.severity == .note)
        #expect(cleanup.line == 8)
        #expect(cleanup.message.contains("deinit of 'KeyVault' wipes memory"))
        #expect(cleanup.message.contains("stored-closure-strong-self"))
    }
}
