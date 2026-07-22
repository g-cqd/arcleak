public import Foundation

/// Per-file facts cache. Parsing + extraction dominate runtime; rules are
/// cheap and always re-run, so only `FileFacts` are cached — findings never
/// go stale relative to rule or config changes.
///
/// The cache is an optimization, so unlike configuration it FAILS OPEN: an
/// unreadable, corrupt, or version-mismatched cache behaves as empty and is
/// overwritten on persist. Entries are keyed by absolute path and validated
/// by a content fingerprint (FNV-1a 64 over bytes + length — identity, not
/// security; a collision merely serves stale facts for one file until its
/// next real change). A tool-version mismatch discards the whole cache, so a
/// facts-schema change can never deserialize into wrong shapes.
public struct FactsCache: Sendable {
    public struct Entry: Sendable, Codable {
        public let fingerprint: String
        public let facts: FileFacts

        public init(fingerprint: String, facts: FileFacts) {
            self.fingerprint = fingerprint
            self.facts = facts
        }
    }

    private struct Payload: Codable {
        var tool: String
        var version: String
        var entries: [String: Entry]
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public static func fingerprint(of data: Data, salt: String = "") -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        for byte in salt.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return "\(String(hash, radix: 16))-\(data.count)"
    }

    public func facts(for path: String, fingerprint: String) -> FileFacts? {
        guard let entry = entries[path], entry.fingerprint == fingerprint else { return nil }
        return entry.facts
    }

    public mutating func update(path: String, fingerprint: String, facts: FileFacts) {
        entries[path] = Entry(fingerprint: fingerprint, facts: facts)
    }

    /// Fail-open load: any failure returns an empty cache.
    public static func load(url: URL) -> FactsCache {
        guard
            let data = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.tool == ToolInfo.name,
            payload.version == ToolInfo.version
        else {
            return FactsCache()
        }
        return FactsCache(entries: payload.entries)
    }

    /// Best-effort persist: creates the directory, writes atomically, and
    /// swallows failures — a read-only cache location must never fail a run.
    public func persist(url: URL) {
        let payload = Payload(tool: ToolInfo.name, version: ToolInfo.version, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
