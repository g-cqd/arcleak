import ArcLeakCore
import Foundation
import ProjectModel
import Testing

/// Pins the 1.x field names of the `--format json` report. The key sets are
/// the contract: a consumer reads them by name, so a renamed or removed field
/// fails here, and so does an added one, until the pinned set is updated
/// alongside `ReportSchema.version`.
@Suite struct JSONContractTests {
    private static let topLevelKeys: Set<String> = [
        "schemaVersion",
        "findings",
        "suppressed",
        "outOfScope",
        "degradedFiles",
        "analyzedFileCount",
        "cacheHits",
        "cacheMisses",
        "wasCancelled",
    ]

    private static let findingKeys: Set<String> = [
        "rule",
        "severity",
        "path",
        "line",
        "column",
        "message",
        "note",
        "related",
        "fingerprintPath",
        "fingerprint",
    ]

    private static let relatedLocationKeys: Set<String> = ["path", "line", "column"]

    @Test func `the JSON report carries the shared schema version and the 1.x fields`() throws {
        let finding = Finding(
            rule: .mutualStrongProperties, severity: .warning,
            path: "Sources/Order.swift", line: 5, column: 9,
            message: "potential retain cycle across types",
            note: "strong links: OrderService.payments → PaymentService",
            related: [RelatedLocation(path: "Sources/Payment.swift", line: 12, column: 5)],
            fingerprintPath: "Sources/Order.swift")
        let report = AnalysisReport(findings: [finding], analyzedFileCount: 2)

        let text = ReportFormatter.format(report, as: .json)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        // The literal, not `ReportSchema.version`: a bump is a contract change and must fail here.
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(Set(object.keys) == Self.topLevelKeys)

        let findings = try #require(object["findings"] as? [[String: Any]])
        let first = try #require(findings.first)
        #expect(Set(first.keys) == Self.findingKeys)

        let related = try #require(first["related"] as? [[String: Any]])
        let location = try #require(related.first)
        #expect(Set(location.keys) == Self.relatedLocationKeys)
    }

    @Test func `optional fields are omitted, not null`() throws {
        let bare = Finding(
            rule: .mutualStrongProperties, severity: .warning,
            path: "a.swift", line: 1, column: 1, message: "m")
        var report = AnalysisReport(
            findings: [bare],
            suppressed: [.init(finding: bare, reason: nil)],
            degradedFiles: [.init(path: "b.swift", detail: "d")],
            analyzedFileCount: 1)
        report.cacheLoadFailure = "x"
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(ReportFormatter.format(report, as: .json).utf8)) as? [String: Any])

        let first = try #require((object["findings"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == Self.findingKeys.subtracting(["note", "related", "fingerprintPath"]))
        #expect(first["line"] is Int)

        let suppressed = try #require((object["suppressed"] as? [[String: Any]])?.first)
        #expect(Set(suppressed.keys) == ["finding"])
        #expect(object["cacheLoadFailure"] as? String == "x")
    }
}
