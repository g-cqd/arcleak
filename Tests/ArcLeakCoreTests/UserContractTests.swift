import ArcLeakCore
import Testing

/// User-extensible knowledge base: `tokenProducer` contracts feed the
/// premature-release rules like built-in token APIs.
@Suite struct UserContractTests {
    private let source = """
        final class Screen {
            let bus = EventBus()
            func attach() {
                _ = bus.subscribe(handler: { print($0) })
            }
            func attachAndDrop() {
                let token = bus.subscribe(handler: { print($0) })
            }
        }
        final class EventBus {
            func subscribe(handler: @escaping (Int) -> Void) -> Int { 0 }
        }
        """

    private var configuration: Configuration {
        Configuration(contracts: [
            .init(
                callee: "subscribe",
                requiredLabels: ["handler"],
                tokenName: "the EventBus subscription",
                template: .tokenProducer
            )
        ])
    }

    @Test("Without the contract, the custom API is invisible")
    func silentWithoutContract() {
        #expect(Analyzer().analyze(source: source, path: "a.swift").findings.isEmpty)
    }

    @Test("With the contract, discarded and scope-local tokens are flagged")
    func contractFlagsTokenMisuse() {
        let findings = Analyzer(configuration: configuration)
            .analyze(source: source, path: "a.swift").findings
        #expect(findings.map(\.rule) == [.unstoredLifetimeToken, .tokenStoredInLocal])
        #expect(findings.first?.message.contains("the EventBus subscription") == true)
    }
}
