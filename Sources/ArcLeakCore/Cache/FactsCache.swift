// ADJSON backs ONLY this internal, version-gated cache coder — its
// reflection-free `@JSONCodable` fast path. Report/SARIF/baseline stay on
// Foundation (they hash encoded bytes across runs; ADJSON differs on number and
// slash formatting, which is harmless only here). `public import` because the
// hand-written `Entry` fast conformance below is public API of the public type.
public import ADJSON
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
        // ADJSON's single-pass byte writer over the reflection-free
        // `ADJSONFastEncodable` graph (`@JSONCodable` structs + the
        // `FactsFastCoding` enums). Default `.rfc8259` options — NO
        // `keyOrder = .sorted`, which would force ADJSON off the streaming writer
        // into a second compact -> re-parse-tape -> re-emit pass and cripple
        // encode. Byte-stability across a decode -> re-encode instead comes from
        // `Payload.__adjsonEncode` emitting the top-level `entries` map in sorted
        // key order (O(files·log files) — it is the only hash-ordered container in
        // the payload). The cache is internal + version-gated, so `2.0`<->`2` and
        // an unescaped `/` are harmless: only this tool version reads these bytes.
        let encoder = ADJSON.JSONEncoder()
        return try encoder.encode(payload)
    }

    fileprivate static func decodePayload(from data: Data) throws -> Payload {
        // Byte-level decode: hand ADJSON a contiguous `[UInt8]` (no Foundation
        // `Data` bridging in the parser); the `@JSONCodable`-generated
        // `_FastDecodeCursor` conformances read each field straight off the tape
        // by statically-known key — no `KeyedDecodingContainer`, no per-key String.
        let decoder = ADJSON.JSONDecoder()
        return try decoder.decode(Payload.self, from: [UInt8](data))
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

// MARK: - Fast ADJSON coding (payload root)

// `FileFacts` and the whole nested model graph get their fast
// `ADJSONFast{Encodable,Decodable}` conformance from `@JSONCodable` (the structs)
// and `FactsFastCoding.swift` (the String-raw enums). `Entry` and `Payload` are
// hand-written here so the root stays nested and — crucially — so `Payload`
// emits the top-level `entries` map in sorted key order: that alone makes the
// persisted cache byte-stable across a decode -> re-encode WITHOUT paying
// ADJSON's `.sorted` whole-tape re-emit (`entries` is the only hash-ordered
// container in the payload; every other collection is an array or a Set-as-array).

extension FactsCache.Entry: ADJSONFastEncodable, ADJSONFastDecodable {
    // ADJSON macro-runtime SPI requires these exact underscored names.
    // swift-format-ignore: NoLeadingUnderscores
    public func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginObject()
        w.key("fingerprint")
        w.string(fingerprint)
        w.comma()
        w.key("facts")
        try facts.__adjsonEncode(into: &w)
        w.endObject()
    }

    // swift-format-ignore: NoLeadingUnderscores
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        Self(
            fingerprint: try c.string("fingerprint"),
            facts: try c.decode(FileFacts.self, "facts"))
    }
}

extension FactsCache.Payload: ADJSONFastEncodable, ADJSONFastDecodable {
    // ADJSON macro-runtime SPI requires these exact underscored names.
    // swift-format-ignore: NoLeadingUnderscores
    func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginObject()
        w.key("tool")
        w.string(tool)
        w.comma()
        w.key("version")
        w.string(version)
        w.comma()
        w.key("entries")
        w.beginObject()
        var first = true
        for (path, entry) in entries.sorted(by: { $0.key < $1.key }) {
            if first { first = false } else { w.comma() }
            w.dynamicKey(path)
            try entry.__adjsonEncode(into: &w)
        }
        w.endObject()
        w.endObject()
    }

    // swift-format-ignore: NoLeadingUnderscores
    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        Self(
            tool: try c.string("tool"),
            version: try c.string("version"),
            entries: try c.decode([String: FactsCache.Entry].self, "entries"))
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
