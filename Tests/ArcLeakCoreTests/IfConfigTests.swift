import ArcLeakCore
import Testing

/// `#if` handling: facts come only from the active clause, and the active
/// clause follows the configured defines.
@Suite struct IfConfigTests {
    private let source = """
        final class Platformy {
            var handler: (() -> Void)?
            func arm() {
                #if CUSTOM_FLAG
                handler = { self.fire() }
                #else
                handler = { [weak self] in self?.fire() }
                #endif
            }
            func fire() {}
        }
        """

    @Test("Inactive strong branch produces no facts")
    func inactiveBranchSilent() {
        let findings = Analyzer().analyze(source: source, path: "test.swift").findings
        #expect(findings.isEmpty)
    }

    @Test("Setting the define flips the active clause and surfaces the cycle")
    func defineActivatesStrongBranch() {
        let configuration = Configuration(defines: ["CUSTOM_FLAG"])
        let findings = Analyzer(configuration: configuration)
            .analyze(source: source, path: "test.swift").findings
        #expect(findings.map(\.rule) == [.storedClosureStrongSelf])
    }

    @Test("Host os() condition selects the matching branch")
    func hostPlatformBranchActive() {
        let platformSource = """
            final class Host {
                var handler: (() -> Void)?
                func arm() {
                    #if os(macOS) || os(Linux)
                    handler = { self.fire() }
                    #else
                    handler = { [weak self] in self?.fire() }
                    #endif
                }
                func fire() {}
            }
            """
        let findings = Analyzer().analyze(source: platformSource, path: "test.swift").findings
        #expect(findings.map(\.rule) == [.storedClosureStrongSelf])
    }
}
