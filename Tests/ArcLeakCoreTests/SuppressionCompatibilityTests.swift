import Foundation
import Testing

@testable import ArcLeakCore

/// Compatibility characterization captured before replacing the implementation. Wire models remain tool-owned.
@Suite struct SuppressionCompatibilityTests {
    @Test func `directives retain their cache shape reasons duplicates and unknown rule behavior`() throws {
        let first = try #require(RuleID(rawValue: "stored-closure-strong-self"))
        let second = try #require(RuleID(rawValue: "timer-retains-self"))
        for prefix in ["al:", "arcleak:"] {
            let parsed = try #require(
                SuppressionDirective.parse(
                    comment:
                        "/* @\(prefix)accept:this stored-closure-strong-self, timer-retains-self stored-closure-strong-self future -- reviewed */",
                    line: 7))
            #expect(parsed.kind == .acceptThis)
            #expect(parsed.line == 7)
            #expect(parsed.reason == "reviewed")
            #expect(parsed.rules == [first, second])
            let data = try JSONEncoder().encode(parsed)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(json.keys) == ["rules", "kind", "line", "reason"])
            let kind = try #require(json["kind"] as? [String: Any])
            #expect(Set(kind.keys) == ["acceptThis"])
            #expect(json["line"] as? Int == 7)
            #expect(json["reason"] as? String == "reviewed")
            #expect(try JSONDecoder().decode(SuppressionDirective.self, from: data) == parsed)
            #expect(SuppressionDirective.parse(comment: "// @\(prefix)accept future", line: 1) == nil)
            #expect(SuppressionDirective.parse(comment: "// prose @\(prefix)accept", line: 1) == nil)
            #expect(SuppressionDirective.parse(comment: "/// @\(prefix)accept", line: 1) == nil)
            #expect(SuppressionDirective.parse(comment: "/** @\(prefix)accept */", line: 1) == nil)
            #expect(SuppressionDirective.parse(comment: "// @\(prefix)accept --  ", line: 1)?.reason == "")
        }
    }

    @Test func `region switches are not nested and same line directives retain order`() throws {
        let first = try #require(RuleID(rawValue: "stored-closure-strong-self"))
        let table = SuppressionTable(directives: [
            SuppressionDirective(rules: [], kind: .regionDisable, line: 1, reason: "outer"),
            SuppressionDirective(rules: [], kind: .regionDisable, line: 2, reason: "inner"),
            SuppressionDirective(rules: [], kind: .regionEnable, line: 3, reason: nil),
            SuppressionDirective(rules: [], kind: .acceptThis, line: 4, reason: nil),
            SuppressionDirective(rules: [], kind: .acceptThis, line: 4, reason: "second"),
        ])
        #expect(table.suppression(for: first, line: 2) == .some("inner"))
        #expect(table.suppression(for: first, line: 3) == nil)
        let withoutReason = table.suppression(for: first, line: 4)
        #expect(try #require(withoutReason) == nil)
    }
}
