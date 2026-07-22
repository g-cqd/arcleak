import Foundation
import ArcLeakCore
import Testing

@Suite struct BaselineAndSarifTests {
    private let leaky = """
    final class Box {
        var handler: (() -> Void)?
        func arm() {
            handler = { self.fire() }
        }
        func fire() {}
    }
    """

    @Test func fingerprintsAreStableAndPositionSensitive() {
        let first = Analyzer().analyze(source: leaky, path: "a.swift").findings
        let second = Analyzer().analyze(source: leaky, path: "a.swift").findings
        #expect(first.map(\.fingerprint) == second.map(\.fingerprint))

        let shifted = Analyzer().analyze(source: "\n" + leaky, path: "a.swift").findings
        #expect(first.first?.fingerprint != shifted.first?.fingerprint)

        let otherFile = Analyzer().analyze(source: leaky, path: "b.swift").findings
        #expect(first.first?.fingerprint != otherFile.first?.fingerprint)
    }

    @Test func baselineFiltersKnownDebtButNotNewBugs() throws {
        let old = Analyzer().analyze(source: leaky, path: "a.swift").findings
        #expect(old.count == 1)

        let path = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-baseline-\(UUID().uuidString).json").path
        try Baseline(findings: old).write(path: path)
        let loaded = try Baseline.load(path: path)

        let grown = """
        final class Box {
            var handler: (() -> Void)?
            func arm() {
                handler = { self.fire() }
            }
            func fire() {}
        }
        final class Second {
            var other: (() -> Void)?
            func arm() {
                other = { self.go() }
            }
            func go() {}
        }
        """
        let current = Analyzer().analyze(source: grown, path: "a.swift").findings
        let (kept, baselined) = loaded.filter(current)
        #expect(baselined.count == 1)
        #expect(kept.count == 1)
        #expect(kept.first?.message.contains("other") == true)
    }

    @Test func malformedBaselineFailsClosed() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-baseline-\(UUID().uuidString).json").path
        try #"{"version": 99, "tool": "arcleak", "fingerprints": []}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: ArcLeakError.self) {
            try Baseline.load(path: path)
        }
    }

    @Test func sarifOutputIsValidAndComplete() throws {
        var report = AnalysisReport()
        report.findings = Analyzer().analyze(source: leaky, path: "Sources/App/Box.swift").findings
        report.analyzedFileCount = 1

        let text = ReportFormatter.format(report, as: .sarif)
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        #expect(json["version"] as? String == "2.1.0")

        let runs = try #require(json["runs"] as? [[String: Any]])
        let run = try #require(runs.first)
        let driver = try #require((run["tool"] as? [String: Any])?["driver"] as? [String: Any])
        #expect(driver["name"] as? String == "arcleak")
        let rules = try #require(driver["rules"] as? [[String: Any]])
        #expect(rules.count == RuleID.allCases.count)

        let results = try #require(run["results"] as? [[String: Any]])
        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result["ruleId"] as? String == "stored-closure-strong-self")
        #expect(result["level"] as? String == "error")
        let location = try #require((result["locations"] as? [[String: Any]])?.first)
        let physical = try #require(location["physicalLocation"] as? [String: Any])
        #expect((physical["artifactLocation"] as? [String: Any])?["uri"] as? String == "Sources/App/Box.swift")
        #expect((result["partialFingerprints"] as? [String: String])?["arcleak/v1"]?.isEmpty == false)
    }
}
