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
