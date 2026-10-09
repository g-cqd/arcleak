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

        #expect(object["schemaVersion"] as? Int == ReportSchema.version)
        #expect(Set(object.keys) == Self.topLevelKeys)

        let findings = try #require(object["findings"] as? [[String: Any]])
        let first = try #require(findings.first)
        #expect(Set(first.keys) == Self.findingKeys)

        let related = try #require(first["related"] as? [[String: Any]])
        let location = try #require(related.first)
        #expect(Set(location.keys) == Self.relatedLocationKeys)
    }
}
