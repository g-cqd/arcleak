import ArcLeakCore
import ProjectModel
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

    /// The back-reference shapes of public delegate leak fixes, pinned as the
    /// rule sees them today: name or declared type ending in delegate or data
    /// source, strong and stored. A strong back-reference named otherwise (a
    /// parent coordinator) is outside the heuristic.
    private let delegateShapes = """
        protocol LoginFlowDelegate: AnyObject {}
        final class AppCoordinator {}
        final class ListDataSource {}
        final class SheetDelegate {}

        final class LoginViewController {
            var delegate: (any LoginFlowDelegate)?
            let flowDelegate: AppCoordinator
            var tableDataSource: ListDataSource?
            var handler: SheetDelegate?
            var parentCoordinator: AppCoordinator?
            weak var weakDelegate: (any LoginFlowDelegate)?
            unowned let dataSource: ListDataSource
            var delegates: [AppCoordinator] = []
            var computedDelegate: SheetDelegate? { nil }

            init(flowDelegate: AppCoordinator, dataSource: ListDataSource) {
                self.flowDelegate = flowDelegate
                self.dataSource = dataSource
            }
        }
        """

    @Test("delegate-strong-property: the delegate shapes of public fixes")
    func delegateShapesWhenEnabled() {
        #expect(Analyzer().analyze(source: delegateShapes, path: "Login.swift").findings.isEmpty)
        let configuration = Configuration(
            rules: ["delegate-strong-property": .init(enabled: true)]
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: delegateShapes, path: "Login.swift").findings
        #expect(findings.map(\.rule).allSatisfy { $0 == .delegateStrongProperty })
        #expect(findings.map(\.line) == [7, 8, 9, 10])
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
        #expect(cleanup.message.hasSuffix("so that cleanup may never run"))
    }

    private let webSource = """
        import WebKit

        final class LoginController {
            let webView = WKWebView()
            var onDone: (() -> Void)?

            func arm() {
                onDone = { self.finish() }
            }

            func finish() {}
        }

        final class PlainController {
            var onDone: (() -> Void)?

            func arm() {
                onDone = { self.finish() }
            }

            func finish() {}
        }
        """

    @Test("sec-session-in-cycle tags cycle findings on a type holding a web view, and adds no finding")
    func secSessionTag() throws {
        let plain = Analyzer().analyze(source: webSource, path: "Login.swift").findings
        #expect(plain.map(\.rule) == [.storedClosureStrongSelf, .storedClosureStrongSelf])
        #expect(plain.allSatisfy { $0.note?.contains("sec-session-in-cycle") != true })

        let configuration = Configuration(rules: ["sec-session-in-cycle": .init(enabled: true)])
        let tagged = Analyzer(configuration: configuration)
            .analyze(source: webSource, path: "Login.swift").findings
        #expect(tagged.map(\.rule) == [.storedClosureStrongSelf, .storedClosureStrongSelf])
        let login = try #require(tagged.first { $0.line == 8 })
        let tag = "security (sec-session-in-cycle, CWE-401): this cycle keeps a WKWebView alive"
        #expect(login.note?.contains(tag) == true)
        let other = try #require(tagged.first { $0.line == 18 })
        #expect(other.note?.contains("sec-session-in-cycle") != true)
        // The note is not part of the fingerprint: baselines keep matching.
        #expect(login.fingerprint == plain.first { $0.line == 8 }?.fingerprint)
    }
}
