import ArcLeakCore
import Foundation
import Testing

/// Fix-it round trip: apply → re-analyze → finding gone, nothing new broken.
@Suite struct FixItTests {
    private func analyze(_ source: String) -> [Finding] {
        Analyzer().analyze(source: source, path: "fix.swift").findings
    }

    @Test("No-signature stored closure: weak self + guard inserted, finding gone")
    func bareClosureRoundTrip() {
        let source = """
            final class Box {
                var handler: (() -> Void)?
                var value = 0
                func arm() {
                    handler = {
                        self.value += 1
                    }
                }
            }
            """
        let findings = analyze(source)
        #expect(findings.map(\.rule) == [.storedClosureStrongSelf])

        let result = FixItApplier.apply(findings: findings, to: source, path: "fix.swift")
        #expect(result.appliedCount == 1)
        #expect(result.fixedSource.contains("[weak self] in"))
        #expect(result.fixedSource.contains("guard let self else { return }"))
        #expect(analyze(result.fixedSource).isEmpty)
    }

    @Test("Parameterized sink closure keeps its parameters, finding gone")
    func signatureClosureRoundTrip() {
        let source = """
            import Combine
            final class Sinker {
                let subject = PassthroughSubject<Int, Never>()
                var cancellables = Set<AnyCancellable>()
                var latest = 0
                func bind() {
                    subject.sink { value in
                        self.latest = value
                    }
                    .store(in: &cancellables)
                }
            }
            """
        let findings = analyze(source)
        #expect(findings.map(\.rule) == [.combineSinkSelfCycle])

        let result = FixItApplier.apply(findings: findings, to: source, path: "fix.swift")
        #expect(result.appliedCount == 1)
        #expect(result.fixedSource.contains("[weak self] value in"))
        #expect(analyze(result.fixedSource).isEmpty)
    }

    @Test("Round trip across the whole Leak fixture corpus")
    func corpusRoundTrip() throws {
        for url in try FixtureRunnerTests.fixtureURLs(in: "Leaks") {
            let source = try String(contentsOf: url, encoding: .utf8)
            let analyzer = Analyzer()
            let before = analyzer.analyze(source: source, path: url.lastPathComponent).findings
            let fixable = before.filter { FixItApplier.fixableRules.contains($0.rule) }
            guard !fixable.isEmpty else { continue }

            let result = FixItApplier.apply(
                findings: fixable,
                to: source,
                path: url.lastPathComponent
            )
            let after = analyzer.analyze(
                source: result.fixedSource,
                path: url.lastPathComponent
            ).findings

            let residualFixable = after.filter {
                FixItApplier.fixableRules.contains($0.rule)
            }
            #expect(
                residualFixable.count == result.skipped.count,
                "\(url.lastPathComponent): applied fixes must eliminate their findings (residual \(residualFixable.map(\.line)), skipped \(result.skipped.map(\.line)))"
            )
            #expect(
                after.count <= before.count,
                "\(url.lastPathComponent): fixing must not introduce findings"
            )

            // Idempotence: a second pass has nothing left to do.
            let again = FixItApplier.apply(
                findings: residualFixable,
                to: result.fixedSource,
                path: url.lastPathComponent
            )
            #expect(again.appliedCount == 0)
        }
    }
}
