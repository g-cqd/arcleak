// AemiJSON backs ONLY this internal, version-gated cache coder — its
// reflection-free `@JSONCodable` fast path. Report/SARIF/baseline stay on
// Foundation (they hash encoded bytes across runs; AemiJSON differs on number and
// slash formatting, which is harmless only here). `public import` because the
// hand-written `Entry` fast conformance below is public API of the public type.
public import AemiJSON

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

/// Per-file facts cache. Parsing + extraction dominate runtime; rules are
/// cheap and always re-run, so only `FileFacts` are cached — findings never
/// go stale relative to rule or config changes.
///
/// The cache is an optimization, so unlike configuration it FAILS OPEN: an
/// unreadable, corrupt, or mismatched cache behaves as empty and is
/// overwritten on persist. Entries are keyed by absolute path and validated
/// by a content fingerprint (FNV-1a 64 over bytes + length — identity, not
/// security; a collision merely serves stale facts for one file until its
/// next real change), salted with the configuration facts depend on. A cache
/// written by another build (see ``BuildIdentity``) is discarded whole, even
/// one of the same version: its extraction code may differ, and a
/// facts-schema change can never deserialize into wrong shapes.
///
/// The header does not validate the payload. A truncated, corrupt, or
/// well-formed payload of the wrong shape is a reported miss; the decoder
/// returns an error and the next persist replaces the file.
public struct FactsCache: Sendable {
    public struct Entry: Sendable, Codable {
        public let fingerprint: String
        public let facts: FileFacts

        public init(fingerprint: String, facts: FileFacts) {
            self.fingerprint = fingerprint
            self.facts = facts
        }
    }

    /// What follows the header line (see ``header(build:)``).
    fileprivate struct Payload: Codable {
        var entries: [String: Entry]
    }

    // MARK: - Coder seam

    // The single encode/decode seam. `load`/`persist` and the `@_spi(Benchmarks)`
    // hooks all route through these two functions, so swapping the JSON coder
    // touches exactly one place and every path is measured/exercised identically.
    fileprivate static func encodePayload(_ payload: Payload) throws -> Data {
        // AemiJSON's single-pass byte writer over the reflection-free
        // `AemiJSONFastEncodable` graph (`@JSONCodable` structs + the
        // `FactsFastCoding` enums). Default `.rfc8259` options — NO
        // `keyOrder = .sorted`, which would force AemiJSON off the streaming writer
        // into a second compact -> re-parse-tape -> re-emit pass and cripple
        // encode. Byte-stability across a decode -> re-encode instead comes from
        // `Payload.__adjsonEncode` emitting the top-level `entries` map in sorted
        // key order (O(files·log files) — it is the only hash-ordered container in
        // the payload). The cache is internal + version-gated, so `2.0`<->`2` and
        // an unescaped `/` are harmless: only this tool version reads these bytes.
        let encoder = AemiJSON.JSONEncoder()
        return try encoder.encode(payload)
    }

    fileprivate static func decodePayload(from data: Data) throws -> Payload {
        // Byte-level decode: hand AemiJSON a contiguous `[UInt8]` (no Foundation
        // `Data` bridging in the parser); the `@JSONCodable`-generated
        // `_FastDecodeCursor` conformances read each field straight off the tape
        // by statically-known key — no `KeyedDecodingContainer`, no per-key String.
        let decoder = AemiJSON.JSONDecoder()
        return try decoder.decode(Payload.self, from: [UInt8](data))
    }

    public private(set) var entries: [String: Entry]

    /// Why the file ``load(url:build:)`` found was not used, when that is
    /// worth telling the user: it could not be read, or it was this build's
    /// cache and still did not decode. nil for a hit, and for the ordinary
    /// misses — no file yet, or one another build wrote.
    public private(set) var loadFailure: String?

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    private init(loadFailure: String) {
        entries = [:]
        self.loadFailure = loadFailure
    }

    /// The line every cache file starts with: the tool, its version and the
    /// build that wrote it (see ``BuildIdentity``). It is plain text, checked
    /// by comparing bytes before any decoder reads the file, so a cache from
    /// another build — or a file that is no cache at all — is never decoded.
    /// No JSON value starts with it either, so an older build, which decodes
    /// the file whole, stops at the first byte with a parse error.
    static func header(build: String) -> String {
        "\(ToolInfo.name) facts \(ToolInfo.version) \(build)"
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
    /// persist holds to the same cap, so it never writes a file load refuses.
    public static let maxCacheBytes = 64 * 1024 * 1024

    /// - Parameter build: the identity of the build reading; a cache another
    ///   build wrote is empty to it. With no identity, no cache is trusted.
    public static func load(url: URL, build: String? = BuildIdentity.current) -> FactsCache {
        guard let build, FileManager.default.fileExists(atPath: url.path) else {
            return FactsCache()
        }
        let data: Data
        do {
            data = try BoundedFileReader.read(path: url.path, cap: maxCacheBytes)
        } catch {
            return FactsCache(loadFailure: "ignored the facts cache at \(url.path): \(reason(error))")
        }
        let header = Data((header(build: build) + "\n").utf8)
        guard data.starts(with: header) else {
            return FactsCache()
        }
        do {
            return FactsCache(entries: try decodePayload(from: data.dropFirst(header.count)).entries)
        } catch {
            return FactsCache(
                loadFailure: "ignored the facts cache at \(url.path), which could not be decoded: \(error)")
        }
    }

    /// Why `error` stopped a read, without the configuration wording the
    /// shared reader's errors carry.
    private static func reason(_ error: ArcLeakError) -> String {
        switch error {
        case .configurationUnreadable(_, let underlying): underlying
        case .configurationInvalid(_, let detail): detail
        default: error.description
        }
    }

    /// Best-effort persist: creates the directory, writes atomically, and
    /// swallows failures — a read-only cache location must never fail a run.
    /// - Parameter build: the identity of the build writing; with none,
    ///   nothing is written, since no build could trust it.
    public func persist(url: URL, build: String? = BuildIdentity.current) {
        guard let build, let body = try? Self.encodePayload(Payload(entries: entries)) else { return }
        let data = Data((Self.header(build: build) + "\n").utf8) + body
        // load refuses a file over the cap, so writing one only spends I/O on
        // bytes no run will read — on every run, once the corpus outgrows the
        // cap. The cache it would have replaced goes too: an over-cap file can
        // never load, and an older one no longer describes this corpus.
        guard data.count <= Self.maxCacheBytes else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Fast AemiJSON coding (payload root)

// `FileFacts` and the whole nested model graph get their fast
// `ADJSONFast{Encodable,Decodable}` conformance from `@JSONCodable` (the structs)
// and `FactsFastCoding.swift` (the String-raw enums). `Entry` and `Payload` are
// hand-written here so the root stays nested and — crucially — so `Payload`
// emits the top-level `entries` map in sorted key order: that alone makes the
// persisted cache byte-stable across a decode -> re-encode WITHOUT paying
// AemiJSON's `.sorted` whole-tape re-emit (`entries` is the only hash-ordered
// container in the payload; every other collection is an array or a Set-as-array).

extension FactsCache.Entry: AemiJSONFastEncodable, AemiJSONFastDecodable {
    // AemiJSON macro-runtime SPI requires these exact underscored names.
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

extension FactsCache.Payload: AemiJSONFastEncodable, AemiJSONFastDecodable {
    // AemiJSON macro-runtime SPI requires these exact underscored names.
    // swift-format-ignore: NoLeadingUnderscores
    func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginObject()
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
        Self(entries: try c.decode([String: FactsCache.Entry].self, "entries"))
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
    /// current decoder. A persisted file's header line is skipped, so the
    /// coder alone is timed.
    public static func decode(_ data: Data) throws -> Payload {
        let body = data.first == UInt8(ascii: "{") ? data : data.drop { $0 != UInt8(ascii: "\n") }.dropFirst()
        return Payload(inner: try FactsCache.decodePayload(from: body))
    }

    /// Encode a payload back to bytes using the cache's current encoder,
    /// without the header line a persisted file starts with.
    public static func encode(_ payload: Payload) throws -> Data {
        try FactsCache.encodePayload(payload.inner)
    }
}
