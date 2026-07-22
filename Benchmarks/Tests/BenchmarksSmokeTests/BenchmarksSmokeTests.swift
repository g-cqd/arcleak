import ArcLeakCore
import Testing

/// The benchmark package's only failure mode is dependency drift against the
/// parent — prove the graph is intact with one real analysis round-trip.
@Suite struct BenchmarksSmokeTests {
    @Test func parentProductIsUsable() {
        let findings = Analyzer()
            .analyze(
                source: "final class B { var h: (() -> Void)?; func a() { h = { self.a() } } }",
                path: "smoke.swift"
            ).findings
        #expect(findings.map(\.rule) == [.storedClosureStrongSelf])
    }
}
