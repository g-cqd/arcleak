import ArcLeakCore
import Testing

@Suite struct SuppressionDirectiveTests {
    @Test func parsesDisableThisWithRulesAndReason() throws {
        let directive = try #require(
            SuppressionDirective.parse(
                comment: "// arcleak:disable:this stored-closure-strong-self, timer-retains-self -- managed elsewhere",
                line: 10
            ))
        #expect(directive.kind == .disableThis)
        #expect(directive.rules == [.storedClosureStrongSelf, .timerRetainsSelf])
        #expect(directive.reason == "managed elsewhere")
    }

    @Test func parsesDeliberate() throws {
        let directive = try #require(
            SuppressionDirective.parse(
                comment: "// arcleak:deliberate -- torn down in shutdown()",
                line: 3
            ))
        #expect(directive.kind == .deliberate)
        #expect(directive.rules.isEmpty)
        #expect(directive.covers(.storedClosureStrongSelf))
        #expect(directive.reason == "torn down in shutdown()")
    }

    @Test func parsesRegionPair() throws {
        let disable = try #require(SuppressionDirective.parse(comment: "// arcleak:disable all", line: 1))
        let enable = try #require(SuppressionDirective.parse(comment: "// arcleak:enable all", line: 9))
        #expect(disable.kind == .regionDisable)
        #expect(enable.kind == .regionEnable)
    }

    @Test func rejectsNonDirectivesAndUnknownRules() {
        #expect(SuppressionDirective.parse(comment: "// regular comment", line: 1) == nil)
        #expect(SuppressionDirective.parse(comment: "// arcleak-expect: foo", line: 1) == nil)
        // A directive naming only unknown rules must suppress nothing, not everything.
        #expect(SuppressionDirective.parse(comment: "// arcleak:disable:this not-a-rule", line: 1) == nil)
    }
}

@Suite struct SuppressionTableTests {
    @Test func thisNextAndDeliberateLineCoverage() {
        let table = SuppressionTable(directives: [
            SuppressionDirective(rules: [], kind: .disableThis, line: 5, reason: nil),
            SuppressionDirective(rules: [], kind: .disableNext, line: 10, reason: nil),
            SuppressionDirective(rules: [], kind: .deliberate, line: 20, reason: "meant"),
        ])
        #expect(table.suppression(for: .storedClosureStrongSelf, line: 5) != nil)
        #expect(table.suppression(for: .storedClosureStrongSelf, line: 6) == nil)
        #expect(table.suppression(for: .storedClosureStrongSelf, line: 11) != nil)
        #expect(table.suppression(for: .storedClosureStrongSelf, line: 10) == nil)
        // deliberate covers its own line and the next
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
