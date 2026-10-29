public import AnalyzerConfiguration
public import ProjectModel
public import SourceCorpus

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
    /// Paths to leave out (ADR-0008, shared by every tool): an entry without `*`, `?` or `[` is a substring of the
    /// path; one with them is a glob relative to ``root``, `/` anchoring it there (`SourceCorpus.PathFilter`).
    public var exclude: [String]
    /// The directory `exclude` globs are relative to: the configuration file's, set by ``load(path:)``. Not part of
    /// the file.
    public var root: String?
    /// Custom `#if` conditions treated as set (the compiler's `-D`); optional
    /// so existing configuration files keep decoding.
    public var defines: [String]?
    /// Analyze the debug build (`DEBUG` set), the default, or the release
    /// build (`false`). Findings in `#if DEBUG` code say they only concern
    /// debug builds.
    public var debugBuild: Bool?
    /// The `os()` names `#if` evaluates as true (`iOS`, `macOS`, ...); nil
    /// takes them from the project files, then from the host.
    public var platforms: [String]?
    /// User-supplied retention contracts extending the knowledge base.
    /// Supports `tokenProducer` (the call returns a lifetime token that must be
    /// owned) and `sinkWrapper` (a custom Combine wrapper such as `React.to`
    /// that returns an AnyCancellable-like token AND whose closure argument is
    /// analyzed for a strong-`self` cycle exactly like `.sink`), and
    /// `disposeBag` / `signalDisposable` (reactive subscriptions whose
    /// Disposable `self` keeps; built in for the RxSwift and SwiftSignalKit
    /// spellings); `anchorLeak` lands with cross-file release plumbing.
    public var contracts: [UserContract]?
    /// Regions (comma-separated: `preview,debug,test,mock,generated,script`,
    /// or `all`) to treat as first-class code: a leak or cycle withheld
    /// because it lives in preview or generated code is reported like any
    /// other, tagged with its region; one in `#if DEBUG` or test code drops
    /// the note that says so. The same key, with the same values, in
    /// deadwood, arcleak and dolly.
    public var includeRegions: String?
    /// Regions to keep out of scope even if `includeRegions` (or `all`)
    /// names them; wins where the two disagree about the same region.
    public var excludeRegions: String?

    private enum CodingKeys: String, CodingKey {
        case rules, exclude, defines, debugBuild, platforms, contracts, includeRegions, excludeRegions
    }

    /// Decodes a partial configuration.
    ///
    /// `rules` and `exclude` are non-optional with memberwise defaults, so the
    /// synthesized `Codable` conformance made both *required* on the wire: a
    /// config supplying only `exclude` was rejected with
    /// `keyNotFound: "rules"`. Every key is optional here, matching what the
    /// memberwise initializer already implies — which is what a CI config
    /// setting nothing but an exclude list needs.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rules =
            try container.decodeIfPresent([String: RuleSettings].self, forKey: .rules) ?? [:]
        self.exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
        self.defines = try container.decodeIfPresent([String].self, forKey: .defines)
        self.debugBuild = try container.decodeIfPresent(Bool.self, forKey: .debugBuild)
        self.platforms = try container.decodeIfPresent([String].self, forKey: .platforms)
        self.contracts = try container.decodeIfPresent([UserContract].self, forKey: .contracts)
        self.includeRegions = try container.decodeIfPresent(String.self, forKey: .includeRegions)
        self.excludeRegions = try container.decodeIfPresent(String.self, forKey: .excludeRegions)
    }

    public init(
        rules: [String: RuleSettings] = [:],
        exclude: [String] = [],
        defines: [String]? = nil,
        debugBuild: Bool? = nil,
        platforms: [String]? = nil,
        contracts: [UserContract]? = nil,
        includeRegions: String? = nil,
        excludeRegions: String? = nil
    ) {
        self.rules = rules
        self.exclude = exclude
        self.defines = defines
        self.debugBuild = debugBuild
        self.platforms = platforms
        self.contracts = contracts
        self.includeRegions = includeRegions
        self.excludeRegions = excludeRegions
    }

    public struct UserContract: Sendable, Codable, Equatable {
        public enum Template: String, Sendable, Codable {
            /// The call returns a lifetime token that must be owned — feeds the
            /// premature-release rules (`unstored-lifetime-token`,
            /// `token-stored-in-local`).
            case tokenProducer
            /// A custom Combine wrapper (`React.to`, `bind`, …) that wraps
            /// `.sink`/`.assign`: the call returns an AnyCancellable-like token
            /// AND its trailing closure is analyzed for strong-`self` capture.
            /// Superset of `tokenProducer` — a discarded token still feeds the
            /// premature-release rules; a strong-`self` closure whose token is
            /// stored on `self` feeds `combine-sink-self-cycle`.
            case sinkWrapper
            /// An RxSwift-style subscription (`subscribe(onNext:)`, `bind`,
            /// `drive`) whose Disposable goes into a bag on `self` through a
            /// chained `.disposed(by:)` (or `addDisposableTo(_:)`): a
            /// strong-`self` closure feeds `combine-sink-self-cycle`. A result
            /// assigned to a member of `self` does not count. Built in for
            /// `subscribe`, `bind` and `drive`.
            case disposeBag
            /// A SwiftSignalKit-style subscription (`signal.start(next:)`)
            /// whose Disposable is passed to `self.<disposable>.set(_:)` or
            /// `.add(_:)`, or assigned to a member of `self`: a strong-`self`
            /// closure feeds `combine-sink-self-cycle`. Built in for
            /// `start(next:)`.
            case signalDisposable
        }

        /// Callee name (`subscribe` in `bus.subscribe(handler:)`, `to` in
        /// `React.to(_:with:)`).
        public var callee: String
        /// Optional receiver base name (`EventBus`/`React` for static calls).
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

    /// The custom conditions set: the configured defines, plus `DEBUG` for a
    /// debug build.
    public var activeDefines: Set<String> {
        var active = Set(defines ?? [])
        if debugBuild ?? true {
            active.insert("DEBUG")
        }
        return active
    }

    public static let `default` = Configuration()

    /// The parsed region selection; throws on an unknown region name from
    /// either key.
    public func regionSelection() throws(UnknownRegionName) -> RegionSelection {
        try RegionSelection(include: includeRegions, exclude: excludeRegions)
    }

    /// What the shared configuration reader checks this tool's keys against (ADR-0020); the shared keys are its own.
    public static let sharedReading = SharedConfiguration.Tool(
        name: ToolInfo.name, fileName: ".arcleak.json", keys: ["rules", "debugBuild", "contracts"])

    /// The configuration of a run (ADR-0020): `explicit` (`--config`) or the configuration directory's
    /// `.swift-analyzers.json` and `.arcleak.json`, merged, every key checked; the built-in default when there is none.
    public static func resolve(
        explicit: String?, currentDirectory: String, analyzedPaths: [String]
    ) throws(ArcLeakError) -> (configuration: Configuration, sources: SharedConfiguration.Resolved) {
        let resolved: SharedConfiguration.Resolved
        do {
            resolved = try SharedConfiguration.resolve(
                for: sharedReading, explicit: explicit, currentDirectory: currentDirectory, analyzedPaths: analyzedPaths
            )
        } catch .unreadable(let path, let reason) {
            throw .configurationUnreadable(path: path, underlying: reason)
        } catch {
            throw .configurationInvalid(path: error.path, detail: error.reason)
        }
        guard let directory = resolved.directory, let last = resolved.sources.last else { return (.default, resolved) }
        let configuration = try decoded(Data(resolved.json), path: last.path, root: directory)
        return (configuration, resolved)
    }

    /// The configuration in the file at `path`, read as `--config` reads it.
    public static func load(path: String) throws(ArcLeakError) -> Configuration {
        try resolve(
            explicit: path, currentDirectory: FileManager.default.currentDirectoryPath, analyzedPaths: []
        ).configuration
    }

    /// `data` decoded and checked: rule ids, value ranges, region names. `root` anchors `exclude` globs.
    static func decoded(_ data: Data, path: String, root: String) throws(ArcLeakError) -> Configuration {
        var config: Configuration
        do {
            config = try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            throw .configurationInvalid(path: path, detail: String(describing: error))
        }
        config.root = root
        if let bogus = config.rules.keys.first(where: { RuleID(rawValue: $0) == nil }) {
            throw .configurationInvalid(path: path, detail: "unknown rule id \"\(bogus)\"")
        }
        if let empty = config.contracts?.first(where: { $0.callee.isEmpty }) {
            _ = empty
            throw .configurationInvalid(path: path, detail: "contract with empty callee")
        }
        do {
            _ = try config.regionSelection()
        } catch {
            throw .configurationInvalid(path: path, detail: error.description)
        }
        return config
    }

    public func isEnabled(_ rule: RuleID) -> Bool {
        rules[rule.rawValue]?.enabled ?? rule.enabledByDefault
    }

    public func severity(for rule: RuleID) -> Severity {
        rules[rule.rawValue]?.severity ?? rule.defaultSeverity
    }

    /// `exclude` as one filter; build it once for many paths.
    public var pathFilter: PathFilter { PathFilter(exclude, root: root) }

    /// Whether `exclude` leaves `path` out; a trailing `/` asks about a directory.
    public func isExcluded(path: String) -> Bool {
        pathFilter.excludes(path)
    }
}
