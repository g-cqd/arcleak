import ArcLeakCore
import Foundation
import Testing

/// Golden runner over the fixture corpus.
///
/// Expectations are `#`-sigil markers in the fixtures themselves:
///   `// #al:expect <rule-id>[, <rule-id>…]`   — a finding on this line
///   `// #al:expect-suppressed <rule-id>`      — a suppressed finding on this line
///
/// The comparison is exact in both directions: a missing finding is a
/// false-negative regression, an extra finding is a false-positive regression.
@Suite struct FixtureRunnerTests {
    struct Expectation: Hashable, CustomStringConvertible {
        let line: Int
        let rule: RuleID
        var description: String { "\(rule.rawValue)@\(line)" }
    }

    static func fixtureURLs(in subdirectory: String) throws -> [URL] {
        let root = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil),
            "Fixtures resource directory missing"
        )
        let directory = root.appending(path: subdirectory)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// Scans for the `#` test-expectation DSL: `// #al:expect <rules>` and
    /// `// #al:expect-suppressed <rules>` (with `#arcleak:` as a synonym). The
    /// `#` sigil marks a fixture assertion, distinct from the `@` directive
    /// sigil the analyzer acts on. `verb` is "expect" or "expect-suppressed".
    static func expectations(in source: String, verb: String) -> Set<Expectation> {
        let markers = ["#al:\(verb) ", "#arcleak:\(verb) "]
        var expected: Set<Expectation> = []
        for (index, lineText) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let marker = markers.first(where: { lineText.contains($0) }),
                let range = lineText.range(of: marker)
            else { continue }
            let list = lineText[range.upperBound...]
            for word in list.split(whereSeparator: { $0 == "," || $0 == " " }) {
                if let rule = RuleID(rawValue: String(word)) {
                    expected.insert(Expectation(line: index + 1, rule: rule))
                }
            }
        }
        return expected
    }

    @Test("Leak fixtures: every expected finding, nothing else")
    func leakFixtures() throws {
        let analyzer = Analyzer()
        for url in try Self.fixtureURLs(in: "Leaks") {
            let source = try String(contentsOf: url, encoding: .utf8)
            let expected = Self.expectations(in: source, verb: "expect")
            #expect(!expected.isEmpty, "\(url.lastPathComponent) has no expectations — dead fixture")

            let result = analyzer.analyze(source: source, path: url.lastPathComponent)
            let actual = Set(result.findings.map { Expectation(line: $0.line, rule: $0.rule) })

            #expect(
                actual == expected,
                """
                \(url.lastPathComponent):
                  missing: \(expected.subtracting(actual).sorted { $0.line < $1.line })
                  extra:   \(actual.subtracting(expected).sorted { $0.line < $1.line })
                """
            )
        }
    }

    @Test("Clean fixtures: zero findings (false-positive gate)")
    func cleanFixtures() throws {
        let analyzer = Analyzer()
        for url in try Self.fixtureURLs(in: "Clean") {
            let source = try String(contentsOf: url, encoding: .utf8)
            let result = analyzer.analyze(source: source, path: url.lastPathComponent)

            #expect(
                result.findings.isEmpty,
                "\(url.lastPathComponent): unexpected findings \(result.findings.map { "\($0.rule.rawValue)@\($0.line)" })"
            )

            let expectedSuppressed = Self.expectations(in: source, verb: "expect-suppressed")
            let actualSuppressed = Set(
                result.suppressed.map { Expectation(line: $0.finding.line, rule: $0.finding.rule) }
            )
            #expect(
                actualSuppressed == expectedSuppressed,
                "\(url.lastPathComponent): suppressed mismatch — expected \(expectedSuppressed), got \(actualSuppressed)"
            )
        }
    }

    @Test("Suppression reasons survive into the report")
    func suppressionReason() throws {
        let url = try #require(
            Self.fixtureURLs(in: "Clean").first { $0.lastPathComponent == "DeliberateSuppression.swift" }
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        let result = Analyzer().analyze(source: source, path: url.lastPathComponent)
        let reason = try #require(result.suppressed.first?.reason)
        #expect(reason.contains("shutdown()"))
    }
}
