import ArcLeakCore
import Foundation
import Testing

/// Where a type lives changes what its leak costs: previews and generated
/// files are withheld, debug-only and test code are labelled, classes the
/// system creates from project files are notes, and `#if os(...)` follows
/// the project's platforms.
@Suite struct ProjectContextTests {
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
            .appending(path: "arcleak-context-\(UUID().uuidString)")
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

    @Test func `a production cycle is reported as before`() async throws {
        let report = try await analyze(["Sources/SampleModel.swift": Self.cycle(named: "SampleModel")])

        #expect(report.findings.map(\.severity) == [.error])
        #expect(report.findings.first?.note?.contains("debug builds") != true)
        #expect(report.findings.first?.note?.contains("test code") != true)
    }

    @Test func `a cycle in #if DEBUG code says it only concerns debug builds`() async throws {
        let source = "#if DEBUG\n" + Self.cycle(named: "DebugPanel") + "\n#endif\n"

        let debug = try await analyze(["Sources/DebugPanel.swift": source])
        let release = try await analyze(
            ["Sources/DebugPanel.swift": source], configuration: Configuration(debugBuild: false))

        #expect(debug.findings.count == 1)
        #expect(debug.findings.first?.note?.contains("only debug builds compile this code") == true)
        #expect(release.findings.isEmpty)
    }

    @Test func `cycles in previews and generated files are withheld with the reason`() async throws {
        let preview = """
            import SwiftUI

            struct SampleView_Previews: PreviewProvider {
            \(Self.cycle(named: "PreviewData"))
                static var previews: some View { Text("Sample") }
            }
            """
        let generated = "// Generated using a template — DO NOT EDIT\n" + Self.cycle(named: "SampleAccessor")

        let report = try await analyze([
            "Sources/SampleView.swift": preview, "Sources/Generated/SampleAccessor.swift": generated,
        ])

        #expect(report.findings.isEmpty)
        #expect(
            Set(report.suppressed.compactMap(\.reason)) == [
                "generated file: fix the generator's input or template", "preview code: previews never ship",
            ])
    }

    @Test func `a cycle in test code says so`() async throws {
        let source = "import Testing\n\n" + Self.cycle(named: "SampleSpy")

        let report = try await analyze(["Sources/SampleSpy.swift": source])

        #expect(report.findings.count == 1)
        #expect(report.findings.first?.note?.contains("test code") == true)
    }

    @Test func `a class the system creates from a project file is a note`() async throws {
        let report = try await analyze([
            "SampleExtension/SampleExtensionHandler.swift": Self.cycle(named: "SampleExtensionHandler"),
            "SampleExtension/Info.plist": """
            <key>NSExtensionPrincipalClass</key>
            <string>$(PRODUCT_MODULE_NAME).SampleExtensionHandler</string>
            """,
        ])

        #expect(report.findings.map(\.severity) == [.note])
        #expect(report.findings.first?.note?.contains("leaks once at most") == true)
    }

    @Test func `#if os() follows the platforms the project builds for`() async throws {
        let source = """
            final class SampleCamera {
                var handler: (() -> Void)?
                func arm() {
                    #if os(iOS)
                    handler = { self.fire() }
                    #else
                    handler = { [weak self] in self?.fire() }
                    #endif
                }
                func fire() {}
            }
            """

        let withoutProject = try await analyze(["Sources/SampleCamera.swift": source])
        let iOSProject = try await analyze([
            "Sources/SampleCamera.swift": source,
            "Sample.xcodeproj/project.pbxproj": "buildSettings = { SDKROOT = iphoneos; };",
        ])

        #expect(withoutProject.findings.isEmpty)
        #expect(iOSProject.findings.count == 1)
    }
}
