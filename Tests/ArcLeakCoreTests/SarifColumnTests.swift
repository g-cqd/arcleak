import ArcLeakCore
import Foundation
import Testing

/// SARIF regions count columns in UTF-16 code units, while arcleak's own
/// columns are swift-syntax's 1-based UTF-8 byte offsets. Converting one to
/// the other must land on the line swift-syntax counted, whatever the line
/// endings, and must not count a byte-order mark (SARIF 2.1.0 §3.30.2).
@Suite struct SarifColumnTests {
    /// Text before the closure that UTF-8 and UTF-16 count differently.
    private static let armLine = #"    func arm() { let _ = "😀é"; handler = { self.fire() } }"#
    private static let bomLine =
        #"final class Bom { var handler: (() -> Void)?; func arm() { let _ = "é"; handler = { self.fire() } }; func fire() {} }"#

    @Test("Line endings and a byte-order mark do not move a column")
    func lineEndingsAndByteOrderMark() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "arcleak-columns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = ["    var handler: (() -> Void)?", Self.armLine, "    func fire() {}", "}", ""]
        let sources = [
            "Crlf.swift": (["final class Crlf {"] + body).joined(separator: "\r\n"),
            "Cr.swift": (["final class Cr {"] + body).joined(separator: "\r"),
            "Bom.swift": "\u{FEFF}" + Self.bomLine + "\n",
        ]
        for (name, source) in sources {
            try source.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
        }
        let report = await Analyzer().analyze(files: sources.keys.map { dir.appending(path: $0).path })
        #expect(report.findings.count == 3)

        let log = try SarifLog(Data(ReportFormatter.format(report, as: .sarif).utf8))
        func column(of name: String) -> Int? {
            log.artifactLocations.first { $0.uri.hasSuffix("/" + name) }?.startColumn
        }
        let armColumn = try Workspace.utf16Column(of: "{ self", in: Self.armLine)
        #expect(column(of: "Crlf.swift") == armColumn)
        #expect(column(of: "Cr.swift") == armColumn)
        #expect(column(of: "Bom.swift") == (try Workspace.utf16Column(of: "{ self", in: Self.bomLine)))
    }

    @Test("A location whose file cannot be read keeps its byte column")
    func unreadableFileKeepsColumn() throws {
        let source = ["final class C {", "    var handler: (() -> Void)?", Self.armLine, "    func fire() {}", "}"]
            .joined(separator: "\n")
        var report = AnalysisReport()
        report.findings = Analyzer().analyze(source: source, path: "Gone.swift").findings
        let finding = try #require(report.findings.first)
        let log = try SarifLog(Data(ReportFormatter.format(report, as: .sarif).utf8))
        #expect(log.artifactLocations.first?.startColumn == finding.column)
    }
}
