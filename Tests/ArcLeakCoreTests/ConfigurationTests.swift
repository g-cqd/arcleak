import Foundation
import ArcLeakCore
import Testing

@Suite struct ConfigurationTests {
    private func write(_ json: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-config-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func unknownRuleIdFailsClosed() throws {
        let path = try write(#"{"rules": {"definitely-not-a-rule": {"enabled": false}}, "exclude": []}"#)
        #expect(throws: ArcLeakError.self) {
            try Configuration.load(path: path)
        }
    }

    @Test func severityOverrideAndDisableApply() throws {
        let path = try write(
            #"{"rules": {"stored-closure-strong-self": {"severity": "warning"}, "timer-retains-self": {"enabled": false}}, "exclude": []}"#
        )
        let config = try Configuration.load(path: path)
        #expect(config.severity(for: .storedClosureStrongSelf) == .warning)
        #expect(!config.isEnabled(.timerRetainsSelf))
        #expect(config.isEnabled(.combineSinkSelfCycle))

        let source = """
        import Foundation
        final class Both {
            var handler: (() -> Void)?
            func arm() {
                handler = { self.fire() }
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.fire() }
            }
            func fire() {}
        }
        """
        let findings = Analyzer(configuration: config)
            .analyze(source: source, path: "test.swift").findings
        #expect(findings.map(\.rule) == [.storedClosureStrongSelf])
        #expect(findings.map(\.severity) == [.warning])
    }

    @Test func excludeMatchesPathSubstring() {
        let config = Configuration(rules: [:], exclude: ["Generated/"])
        #expect(config.isExcluded(path: "/repo/Sources/Generated/API.swift"))
        #expect(!config.isExcluded(path: "/repo/Sources/App/API.swift"))
    }
}
