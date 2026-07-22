import Foundation

/// Analyzer configuration, loadable from `.arcleak.json`.
///
/// Malformed configuration is a hard, typed failure — the analyzer fails closed
/// rather than running with rules silently dropped.
public struct Configuration: Sendable, Codable, Equatable {
    public struct RuleSettings: Sendable, Codable, Equatable {
        public var enabled: Bool?
        public var severity: Severity?

        public init(enabled: Bool? = nil, severity: Severity? = nil) {
            self.enabled = enabled
            self.severity = severity
        }
    }

    /// Keyed by `RuleID` raw value. Unknown keys are rejected at load time so a
    /// typo can't silently disable nothing.
    public var rules: [String: RuleSettings]
    /// Path substrings to exclude (matched against the file path).
    public var exclude: [String]
    /// Custom `#if` conditions treated as set (the compiler's `-D`); optional
    /// so existing configuration files keep decoding.
    public var defines: [String]?

    public init(rules: [String: RuleSettings] = [:], exclude: [String] = [], defines: [String]? = nil) {
        self.rules = rules
        self.exclude = exclude
        self.defines = defines
    }

    public var activeDefines: Set<String> { Set(defines ?? []) }

    public static let `default` = Configuration()

    public static func load(path: String) throws(ArcLeakError) -> Configuration {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw .configurationUnreadable(path: path, underlying: String(describing: error))
        }
        let config: Configuration
        do {
            config = try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            throw .configurationInvalid(path: path, detail: String(describing: error))
        }
        if let bogus = config.rules.keys.first(where: { RuleID(rawValue: $0) == nil }) {
            throw .configurationInvalid(path: path, detail: "unknown rule id \"\(bogus)\"")
        }
        return config
    }

    public func isEnabled(_ rule: RuleID) -> Bool {
        rules[rule.rawValue]?.enabled ?? true
    }

    public func severity(for rule: RuleID) -> Severity {
        rules[rule.rawValue]?.severity ?? rule.defaultSeverity
    }

    public func isExcluded(path: String) -> Bool {
        exclude.contains { !$0.isEmpty && path.contains($0) }
    }
}
