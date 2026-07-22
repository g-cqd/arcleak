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
    /// User-supplied retention contracts extending the knowledge base.
    /// v1 supports `tokenProducer` (the call returns a lifetime token that
    /// must be owned); `anchorLeak` lands with cross-file release plumbing.
    public var contracts: [UserContract]?

    public init(
        rules: [String: RuleSettings] = [:],
        exclude: [String] = [],
        defines: [String]? = nil,
        contracts: [UserContract]? = nil
    ) {
        self.rules = rules
        self.exclude = exclude
        self.defines = defines
        self.contracts = contracts
    }

    public struct UserContract: Sendable, Codable, Equatable {
        public enum Template: String, Sendable, Codable {
            case tokenProducer
        }

        /// Callee name (`subscribe` in `bus.subscribe(handler:)`).
        public var callee: String
        /// Optional receiver base name (`EventBus` for static calls).
        public var base: String?
        /// Labels that must all be present for the call to match.
        public var requiredLabels: [String]?
        /// Human name used in diagnostics ("the subscription token").
        public var tokenName: String?
        public var template: Template

        public init(
            callee: String,
            base: String? = nil,
            requiredLabels: [String]? = nil,
            tokenName: String? = nil,
            template: Template
        ) {
            self.callee = callee
            self.base = base
            self.requiredLabels = requiredLabels
            self.tokenName = tokenName
            self.template = template
        }
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
        if let empty = config.contracts?.first(where: { $0.callee.isEmpty }) {
            _ = empty
            throw .configurationInvalid(path: path, detail: "contract with empty callee")
        }
        return config
    }

    public func isEnabled(_ rule: RuleID) -> Bool {
        rules[rule.rawValue]?.enabled ?? rule.enabledByDefault
    }

    public func severity(for rule: RuleID) -> Severity {
        rules[rule.rawValue]?.severity ?? rule.defaultSeverity
    }

    public func isExcluded(path: String) -> Bool {
        exclude.contains { !$0.isEmpty && path.contains($0) }
    }
}
