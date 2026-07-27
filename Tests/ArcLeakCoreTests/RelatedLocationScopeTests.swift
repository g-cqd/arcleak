//  RelatedLocationScopeTests.swift
//  arcleak
//
//  A cross-type retain cycle anchors at the alphabetically-first type in its
//  strongly-connected component — arbitrary with respect to a pull request's
//  diff. Matching scope on the anchor alone hid the cycle from the very change
//  that introduced it whenever the anchor lived in another file.

import Foundation
import Testing

@testable import ArcLeakCore

@Suite struct RelatedLocationScopeTests {
    private static let corpus =
        "/Users/gc/Developer/ongoing/swift/arcleak/Tests/ArcLeakCoreTests/Fixtures/Corpus/MutualPair"
    private static var available: Bool { FileManager.default.fileExists(atPath: corpus) }

    private func analyze(scope: ReportScope?) async -> AnalysisReport {
        let files =
            (try? FileManager.default.contentsOfDirectory(atPath: Self.corpus))?
            .filter { $0.hasSuffix(".swift") }
            .map { Self.corpus + "/" + $0 } ?? []
        return await Analyzer().analyze(files: files, reportScope: scope)
    }

    @Test(
        "A cross-file cycle carries every link as a related location",
        .enabled(if: RelatedLocationScopeTests.available))
    func cycleCarriesRelatedLocations() async throws {
        let report = await analyze(scope: nil)
        let cycle = try #require(report.findings.first { $0.rule == .mutualStrongProperties })
        #expect(!cycle.related.isEmpty)
        // The anchor is not among its own related locations.
        #expect(!cycle.related.contains { $0.path == cycle.path })
    }

    @Test(
        "Scoping to a non-anchor file still reports the cycle",
        .enabled(if: RelatedLocationScopeTests.available))
    func scopeMatchesNonAnchorFile() async throws {
        let unscoped = await analyze(scope: nil)
        let cycle = try #require(unscoped.findings.first { $0.rule == .mutualStrongProperties })
        let other = try #require(cycle.related.first).path
        #expect(other != cycle.path)

        let report = await analyze(scope: ReportScope(files: [other]))
        #expect(report.findings.contains { $0.rule == .mutualStrongProperties })
    }

    @Test(
        "Related locations do not enter the fingerprint",
        .enabled(if: RelatedLocationScopeTests.available))
    func relatedDoesNotAffectFingerprint() async throws {
        let report = await analyze(scope: nil)
        let cycle = try #require(report.findings.first { $0.rule == .mutualStrongProperties })
        let bare = Finding(
            rule: cycle.rule, severity: cycle.severity, path: cycle.path,
            line: cycle.line, column: cycle.column, message: cycle.message, note: cycle.note
        )
        // A baseline written before related locations existed must keep matching.
        #expect(bare.fingerprint == cycle.fingerprint)
    }
}
