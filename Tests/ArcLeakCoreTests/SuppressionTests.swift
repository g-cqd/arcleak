import ArcLeakCore
import Testing

@Suite struct SuppressionDirectiveTests {
    @Test func parsesAcceptThisWithRulesAndReason() throws {
        let directive = try #require(
            SuppressionDirective.parse(
                comment:
                    "// @al:accept:this stored-closure-strong-self, timer-retains-self -- managed elsewhere",
                line: 10
            ))
        #expect(directive.kind == .acceptThis)
        #expect(directive.rules == [.storedClosureStrongSelf, .timerRetainsSelf])
        #expect(directive.reason == "managed elsewhere")
    }

    @Test func parsesAccept() throws {
        let directive = try #require(
            SuppressionDirective.parse(
                comment: "// @al:accept -- torn down in shutdown()",
                line: 3
            ))
        #expect(directive.kind == .accept)
        #expect(directive.rules.isEmpty)
        #expect(directive.covers(.storedClosureStrongSelf))
        #expect(directive.reason == "torn down in shutdown()")
    }

    @Test func arcleakNamespaceIsSynonymForAl() throws {
        let short = try #require(SuppressionDirective.parse(comment: "// @al:accept:next", line: 1))
        let long = try #require(
            SuppressionDirective.parse(comment: "// @arcleak:accept:next", line: 1))
        #expect(short.kind == .acceptNext)
        #expect(long.kind == .acceptNext)
    }

    @Test func parsesRegionPair() throws {
        let disable = try #require(SuppressionDirective.parse(comment: "// @al:disable all", line: 1))
        let enable = try #require(SuppressionDirective.parse(comment: "// @al:enable all", line: 9))
        #expect(disable.kind == .regionDisable)
        #expect(enable.kind == .regionEnable)
    }

    @Test func rejectsNonDirectivesAndUnknownRules() {
        #expect(SuppressionDirective.parse(comment: "// regular comment", line: 1) == nil)
        // `#`-sigil markers are expectations, not directives — never parsed here.
        #expect(SuppressionDirective.parse(comment: "// #al:expect foo", line: 1) == nil)
        // A missing `@` sigil is not a directive.
        #expect(SuppressionDirective.parse(comment: "// al:accept", line: 1) == nil)
        // A rule-scoped verb naming only unknown rules suppresses nothing.
        #expect(SuppressionDirective.parse(comment: "// @al:accept:this not-a-rule", line: 1) == nil)
    }
}

@Suite struct SuppressionTableTests {
    @Test func thisNextAndAcceptLineCoverage() {
        let table = SuppressionTable(directives: [
            SuppressionDirective(rules: [], kind: .acceptThis, line: 5, reason: nil),
            SuppressionDirective(rules: [], kind: .acceptNext, line: 10, reason: nil),
            SuppressionDirective(rules: [], kind: .accept, line: 20, reason: "meant"),
        ])
        #expect(table.suppression(for: .storedClosureStrongSelf, line: 5) != nil)
        #expect(table.suppression(for: .storedClosureStrongSelf, line: 6) == nil)
        #expect(table.suppression(for: .storedClosureStrongSelf, line: 11) != nil)
        #expect(table.suppression(for: .storedClosureStrongSelf, line: 10) == nil)
        #expect(table.suppression(for: .timerRetainsSelf, line: 20) != nil)
        #expect(table.suppression(for: .timerRetainsSelf, line: 21) != nil)
        #expect(table.suppression(for: .timerRetainsSelf, line: 22) == nil)
    }

    @Test func regionScopingRespectsRuleFilter() {
        let table = SuppressionTable(directives: [
            SuppressionDirective(rules: [.timerRetainsSelf], kind: .regionDisable, line: 3, reason: nil),
            SuppressionDirective(rules: [.timerRetainsSelf], kind: .regionEnable, line: 30, reason: nil),
        ])
        #expect(table.suppression(for: .timerRetainsSelf, line: 15) != nil)
        #expect(table.suppression(for: .storedClosureStrongSelf, line: 15) == nil)
        #expect(table.suppression(for: .timerRetainsSelf, line: 31) == nil)
    }

    @Test func unbalancedDisableRunsToEndOfFile() {
        let table = SuppressionTable(directives: [
            SuppressionDirective(rules: [], kind: .regionDisable, line: 1, reason: nil)
        ])
        #expect(table.suppression(for: .combineSinkSelfCycle, line: 9999) != nil)
    }
}
