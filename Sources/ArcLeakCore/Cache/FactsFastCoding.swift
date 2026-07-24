//  ADJSON fast-path coding for the facts payload's non-struct leaves.
//
//  The `@JSONCodable` macro emits ADJSON's reflection-free
//  `ADJSONFast{Decodable,Encodable}` conformance for a struct (see the model
//  types + `FactsCache.swift`). It only handles structs, so the String-raw-value
//  enums that appear as frequent struct fields get a small hand-written fast
//  conformance here so they still decode straight off the tape (the decisive
//  win): `ReferenceStrength` (on every stored property — the payload's densest
//  field), `ReleaseSite.Kind`, and `APICallFact.UpstreamFiniteness`.
//
//  The associated-value / non-raw enums the cache also encodes —
//  `SelfCaptureKind`, `ResultConsumption`, `APICallFact.Kind`, and
//  `SuppressionDirective.Kind` — plus the `Set<…>` fields are intentionally LEFT
//  on ADJSON's generic Codable bridge rather than hand-specialised. With the
//  upstream `JSONWriter.init(adopting:)` COW fix that bridge is O(n), those
//  shapes are rare in a real corpus, and the cache is internal + version-gated,
//  so the wire only has to be self-consistent — key order and number spelling
//  are irrelevant.
public import ADJSON

// MARK: - String-raw-value enums

// A `RawRepresentable` whose raw value is a `String` encodes as that bare string
// and decodes back through `init(rawValue:)` — the same one-token shape the
// synthesized `Codable` produces, but straight off the tape with no container.
// `public` so these satisfy the fast-protocol requirements for the public enums
// below (their conformances are public API of ArcLeakCore).
extension ADJSONFastEncodable where Self: RawRepresentable, RawValue == String {
    // ADJSON macro-runtime SPI requires these exact underscored names.
    // swift-format-ignore: NoLeadingUnderscores
    public func __adjsonEncode(into w: inout _JSONByteWriter) { w.string(rawValue) }
}

extension ADJSONFastDecodable where Self: RawRepresentable, RawValue == String {
    // ADJSON macro-runtime SPI requires these exact underscored names.
    // swift-format-ignore: NoLeadingUnderscores
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        let raw = try c.currentString()
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "unknown \(Self.self) raw value \"\(raw)\""))
        }
        return value
    }
}

// The String-raw enums that appear as direct struct fields in the cached graph.
extension ReferenceStrength: ADJSONFastEncodable, ADJSONFastDecodable {}
extension ReleaseSite.Kind: ADJSONFastEncodable, ADJSONFastDecodable {}
extension APICallFact.UpstreamFiniteness: ADJSONFastEncodable, ADJSONFastDecodable {}

// `RuleID` (the elements of `SuppressionDirective.rules`) — same String-raw
// treatment, plus `Comparable` so the `Set<RuleID>` below can sort. The fast
// conformance is consulted only on the ADJSON cache path; RuleID's Foundation
// Codable (config, baselines, SARIF) is untouched.
extension RuleID: ADJSONFastEncodable, ADJSONFastDecodable {}
extension RuleID: Comparable {
    public static func < (lhs: RuleID, rhs: RuleID) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Sets (sorted for byte-stability)

// Swift `Set` has no stable iteration order across constructions (per-process
// hash seed + table capacity), so a Set-as-array is NOT byte-stable across a
// load -> re-persist. Encode the payload's Set fields (`TypeFacts`'s name sets,
// `SuppressionDirective.rules`) as a SORTED array instead: the cache then
// round-trips byte-identically AND is reproducible across processes — the
// Foundation coder it replaces sorted only dictionary keys, never Set elements.
// `@retroactive`: this module owns neither `Set` (stdlib) nor the protocol
// (ADJSON), and ADJSON deliberately ships no `Set` conformance. The risk the
// warning guards against — Swift later conforming `Set` itself — does not apply
// to a private macro-runtime SPI protocol, and the conformance is consulted only
// on the internal cache path.
extension Set: @retroactive ADJSONFastEncodable where Element: ADJSONFastEncodable & Comparable {
    // swift-format-ignore: NoLeadingUnderscores
    public func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginArray()
        var first = true
        for element in sorted() {
            if first { first = false } else { w.comma() }
            try element.__adjsonEncode(into: &w)
        }
        w.endArray()
    }
}

extension Set: @retroactive ADJSONFastDecodable where Element: ADJSONFastDecodable {
    // swift-format-ignore: NoLeadingUnderscores
    public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Set<Element> {
        Set(try c.fastArray(Element.self))
    }
}
