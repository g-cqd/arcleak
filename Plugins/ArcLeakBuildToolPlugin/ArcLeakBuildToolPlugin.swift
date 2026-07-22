import Foundation
import PackagePlugin

/// Runs arcleak over each target's sources during the build. Findings surface
/// as inline diagnostics because the CLI emits `path:line:col: warning|error:`
/// lines, which SwiftPM and Xcode parse from build-tool output. Error-severity
/// findings make the tool exit non-zero, failing the build; warnings keep it
/// green — mirroring compiler semantics.
@main
struct ArcLeakBuildToolPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target as? SourceModuleTarget else { return [] }
        let sources = module.sourceFiles(withSuffix: "swift").map(\.url)
        guard !sources.isEmpty else { return [] }

        let stamp = context.pluginWorkDirectoryURL
            .appending(path: "arcleak-\(target.name).stamp")

        let cache = context.pluginWorkDirectoryURL
            .appending(path: "arcleak-facts-cache.json")

        var arguments = ["analyze", "--format", "xcode"]
        arguments += ["--stamp", stamp.path(percentEncoded: false)]
        arguments += ["--cache-path", cache.path(percentEncoded: false)]
        let config = context.package.directoryURL.appending(path: ".arcleak.json")
        if FileManager.default.fileExists(atPath: config.path(percentEncoded: false)) {
            arguments += ["--config", config.path(percentEncoded: false)]
        }
        arguments += sources.map { $0.path(percentEncoded: false) }

        return [
            .buildCommand(
                displayName: "arcleak \(target.name)",
                executable: try context.tool(named: "arcleak").url,
                arguments: arguments,
                inputFiles: sources,
                outputFiles: [stamp]
            )
        ]
    }
}
