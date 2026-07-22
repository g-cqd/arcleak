import Foundation
import PackagePlugin

/// `swift package arcleak [arcleak arguments]` — on-demand analysis of the
/// package. With no explicit paths, analyzes every source target's directory.
@main
struct ArcLeakCommandPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "arcleak")

        var forwarded = arguments
        let hasExplicitPaths = forwarded.contains { !$0.hasPrefix("-") }
        if !hasExplicitPaths {
            let targetDirectories = context.package.targets
                .compactMap { ($0 as? SourceModuleTarget)?.directoryURL.path(percentEncoded: false) }
            forwarded += targetDirectories
        }

        let process = Process()
        process.executableURL = tool.url
        process.arguments = ["analyze"] + forwarded
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("arcleak reported error-severity findings")
        }
    }
}
