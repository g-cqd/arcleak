import ArcLeakCore
import Foundation
import Testing

/// `--include`/`--exclude`: a leak or cycle withheld because it lives in
/// preview or generated code is reported like any other once the region is
/// included, tagged so it stays filterable; one in `#if DEBUG` or test code
/// drops the reassuring note instead, since nothing was ever withheld to
/// promote. `mock` and `script` name no region arcleak withholds or
/// annotates today, so including them changes nothing.
@Suite struct RegionIncludeTests {
    /// A stored closure capturing `self` strongly: a cycle in production.
    private static func cycle(named name: String) -> String {
        """
        final class \(name) {
            var handler: (() -> Void)?
            func arm() {
                handler = { self.fire() }
            }
            func fire() {}
        }
        """
    }

    /// Writes the files into a fresh directory, analyzes them as the CLI
    /// would (Swift files, project files), and removes the directory.
    private func analyze(
        _ files: [String: String],
        configuration: Configuration = .default
    ) async throws -> AnalysisReport {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-include-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var swiftFiles: [String] = []
        var projectFiles: [String] = []
        for (relativePath, contents) in files {
            let url = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            if SourceDiscovery.isProjectFile(url.path) {
                projectFiles.append(url.path)
            } else {
                swiftFiles.append(url.path)
            }
        }
        return await Analyzer(configuration: configuration)
            .analyze(files: swiftFiles.sorted(), projectFiles: projectFiles.sorted())
    }

    // MARK: - Generated

    private static let generatedFile =
        "// Generated using a template — DO NOT EDIT\n" + cycle(named: "SampleAccessor")

    @Test func `including generated reports the cycle it would otherwise withhold, tagged`() async throws {
        let configuration = Configuration(includeRegions: "generated")
        let report = try await analyze(
            ["Sources/Generated/SampleAccessor.swift": Self.generatedFile], configuration: configuration)

        #expect(report.suppressed.isEmpty)
        let finding = try #require(report.findings.first)
        #expect(finding.severity == .error)
        #expect(finding.note?.contains("region: generated") == true)
    }

    @Test func `excluding generated wins over including everything`() async throws {
        let configuration = Configuration(includeRegions: "all", excludeRegions: "generated")
        let report = try await analyze(
            ["Sources/Generated/SampleAccessor.swift": Self.generatedFile], configuration: configuration)

        #expect(report.findings.isEmpty)
        #expect(report.suppressed.first?.reason == "generated file: fix the generator's input or template")
    }

    // MARK: - Preview

    private static let previewFile = """
        import SwiftUI

        struct SampleView_Previews: PreviewProvider {
        \(cycle(named: "PreviewData"))
            static var previews: some View { Text("Sample") }
        }
        """

    @Test func `including preview reports the cycle it would otherwise withhold, tagged`() async throws {
        let configuration = Configuration(includeRegions: "preview")
        let report = try await analyze(
            ["Sources/SampleView.swift": Self.previewFile], configuration: configuration)

        #expect(report.suppressed.isEmpty)
        let finding = try #require(report.findings.first)
        #expect(finding.note?.contains("region: preview") == true)
    }

    // MARK: - Debug

    private static let debugFile = "#if DEBUG\n" + cycle(named: "DebugPanel") + "\n#endif\n"

    @Test func `including debug drops the reassuring note`() async throws {
        let configuration = Configuration(includeRegions: "debug")
        let report = try await analyze(
            ["Sources/DebugPanel.swift": Self.debugFile], configuration: configuration)

        let finding = try #require(report.findings.first)
        #expect(finding.note?.contains("only debug builds compile this code") != true)
    }

    @Test func `debug stays reassured by default`() async throws {
        let report = try await analyze(["Sources/DebugPanel.swift": Self.debugFile])

        let finding = try #require(report.findings.first)
        #expect(finding.note?.contains("only debug builds compile this code") == true)
    }

    // MARK: - Test

    private static let testCodeFile = "import Testing\n\n" + cycle(named: "SampleSpy")

    @Test func `including test drops the reassuring note`() async throws {
        let configuration = Configuration(includeRegions: "test")
        let report = try await analyze(
            ["Sources/SampleSpy.swift": Self.testCodeFile], configuration: configuration)

        let finding = try #require(report.findings.first)
        #expect(finding.note?.contains("test code") != true)
    }

    // MARK: - No region to toggle

    @Test func `including mock and script changes nothing: arcleak withholds neither`() async throws {
        // Two different temporary roots, so findings compare by shape
        // (rule, severity, note) rather than by their (necessarily
        // different) absolute path.
        let source = Self.cycle(named: "SampleMock")
        let defaultReport = try await analyze(["Sources/Mocks/SampleMock.swift": source])
        let included = try await analyze(
            ["Sources/Mocks/SampleMock.swift": source],
            configuration: Configuration(includeRegions: "mock,script"))

        let shape = { (report: AnalysisReport) in
            report.findings.map { "\($0.rule)/\($0.severity)/\($0.note ?? "")" }
        }
        #expect(shape(defaultReport) == shape(included))
        #expect(defaultReport.suppressed.count == included.suppressed.count)
    }

    // MARK: - Unknown region name

    @Test func `an unknown region name fails the config, not silently`() {
        #expect(throws: (any Error).self) {
            try Configuration(includeRegions: "bogus").regionSelection()
        }
    }
}
