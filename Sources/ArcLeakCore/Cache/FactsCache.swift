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

    fileprivate struct Payload: Codable {
        var tool: String
        var version: String
        var entries: [String: Entry]
    }

    // MARK: - Coder seam

    // The single encode/decode seam. `load`/`persist` and the `@_spi(Benchmarks)`
    // hooks all route through these two functions, so swapping the JSON coder
    // touches exactly one place and every path is measured/exercised identically.
    fileprivate static func encodePayload(_ payload: Payload) throws -> Data {
        // `.sortedKeys` makes the persisted cache byte-stable across a
        // decode -> re-encode: the only hash-ordered container in the payload is
        // the top-level `entries` map (every other collection is an array or a
        // Set-as-array), and sorting its keys pins its order. Within a process
        // Set element order is already stable (one hash seed), so the whole
        // round-trip is byte-identical.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    fileprivate static func decodePayload(from data: Data) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: data)
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public static func fingerprint(of data: Data, salt: String = "") -> String {
        let prime: UInt64 = 0x0000_0100_0000_01b3
        // FNV-1a over the raw contiguous buffer. `withUnsafeBytes` is the only
        // fast path — `Data`'s element iterator is O(n) with per-byte bridging
        // overhead, and this runs on every file on every run (even cache hits).
        // Invariant: the buffer never escapes the closure; `unsafe` is confined
        // here and covered by the fingerprint stability tests.
        var hash: UInt64 = unsafe data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt64 in
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            let count = raw.count
            var i = 0
            while i < count {
                h ^= UInt64(unsafe raw[i])
                h &*= prime
                i += 1
            }
            return h
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

    /// Fail-open load: any failure — including an over-cap file — returns an
    /// empty cache (the cache is an optimization, never a trust boundary).
    public static let maxCacheBytes = 64 * 1024 * 1024

    public static func load(url: URL) -> FactsCache {
        guard
            let data = try? BoundedFileReader.read(path: url.path, cap: maxCacheBytes),
            let payload = try? decodePayload(from: data),
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
        guard let data = try? Self.encodePayload(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Benchmark hooks (SPI)

/// SPI surface for the local `Benchmarks/` package: time the cache's
/// encode/decode seam in isolation on a real payload, independent of file I/O
/// and the rest of the analysis pipeline. Not supported public API. The opaque
/// `Payload` handle hides the cache's private payload shape while letting the
/// encode benchmark reuse one decoded instance across iterations. Both hooks
/// route through the exact seam `load`/`persist` use, so a coder swap is
/// measured here identically to production.
@_spi(Benchmarks)
public enum FactsCacheBenchmark {
    public struct Payload: Sendable {
        fileprivate let inner: FactsCache.Payload
        public var entryCount: Int { inner.entries.count }
    }

    /// Decode facts.json bytes into an opaque payload using the cache's
    /// current decoder.
    public static func decode(_ data: Data) throws -> Payload {
        Payload(inner: try FactsCache.decodePayload(from: data))
    }

    /// Encode a payload back to bytes using the cache's current encoder.
    public static func encode(_ payload: Payload) throws -> Data {
        try FactsCache.encodePayload(payload.inner)
    }
}
