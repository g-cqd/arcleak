import ProjectModel
import ReportSupport

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A set of accepted finding fingerprints — pre-existing debt a team adopts
/// the tool against without a wall of noise. Baselined findings are filtered
/// out of the report (and the exit code), but their count stays visible.
///
/// Fingerprints include line/column, so unrelated edits above a finding shift
/// it out of the baseline — regenerate with `--write-baseline` after big
/// moves. That is the deliberate trade against fuzzy matching silently
/// swallowing *new* bugs.
public struct Baseline: Sendable, Equatable {
    public let fingerprints: Set<String>

    public init(fingerprints: Set<String>) {
        self.fingerprints = fingerprints
    }

    public init(findings: [Finding]) {
        self.init(fingerprints: Set(findings.map(\.fingerprint)))
    }

    public func contains(_ finding: Finding) -> Bool {
        fingerprints.contains(finding.fingerprint)
    }

    /// Splits findings into (kept, baselined).
    public func filter(_ findings: [Finding]) -> (kept: [Finding], baselined: [Finding]) {
        let (kept, baselined) = findings.partitioned(by: contains)
        return (kept, baselined)
    }

    // MARK: - Persistence (versioned JSON, deterministic ordering)

    public static func load(path: String) throws(ArcLeakError) -> Baseline {
        let data = try BoundedFileReader.read(path: path)
        let file: BaselineFile
        do {
            file = try JSONDecoder().decode(BaselineFile.self, from: data)
        } catch {
            throw .configurationInvalid(path: path, detail: String(describing: error))
        }
        do {
            return Baseline(fingerprints: Set(try file.validated(requiringVersion: true).fingerprints))
        } catch {
            throw .configurationInvalid(path: path, detail: error.description)
        }
    }

    public func write(path: String) throws(ArcLeakError) {
        let payload = BaselineFile(tool: ToolInfo.name, fingerprints: fingerprints, versioned: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(payload)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw .configurationUnreadable(path: path, underlying: String(describing: error))
        }
    }
}

extension Finding {
    /// Stable identity for baselines and SARIF `partialFingerprints`.
    ///
    /// Hashes `fingerprintPath` when set — the repository-relative spelling —
    /// so the same finding fingerprints identically on a developer's machine
    /// and a CI runner, regardless of checkout location or how paths are
    /// displayed.
    /// FNV-1a 64-bit over the finding's identifying fields — identity hashing,
    /// not security; collisions merely over-baseline one finding.
    public var fingerprint: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in "\(rule.rawValue)|\(fingerprintPath ?? path)|\(line)|\(column)|\(message)".utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(hash, radix: 16, uppercase: false)
    }
}
