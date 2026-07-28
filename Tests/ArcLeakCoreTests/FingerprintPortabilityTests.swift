//  FingerprintPortabilityTests.swift
//  arcleak
//
//  A baseline is only useful if the same finding fingerprints identically
//  wherever it is computed. `--relative-to` achieves that only when the caller
//  remembers it: before fingerprints were anchored automatically, a run with
//  the flag and a run without shared *zero* fingerprints, so a baseline written
//  locally suppressed nothing in CI — silently, because a fingerprint matching
//  nothing is indistinguishable from a genuinely new finding.

import Foundation
import Testing

@testable import ArcLeakCore

@Suite struct FingerprintPortabilityTests {
    /// Two checkouts of the same sources, each a repository of its own.
    private func makeCheckout(named name: String) throws -> [String] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcleak-fp-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A `.git` entry is what marks the anchor; its contents are irrelevant.
        try Data().write(to: root.appendingPathComponent(".git"))
        let source = """
            import Combine
            final class Holder {
                var bag: Set<AnyCancellable> = []
                var handler: (() -> Void)?
                func setup() { handler = { self.work() } }
                func work() {}
            }
            """
        let file = root.appendingPathComponent("Holder.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        return [file.path]
    }

    @Test("The same code in two checkouts fingerprints identically")
    func portableAcrossCheckouts() async throws {
        let here = await Analyzer().analyze(files: try makeCheckout(named: "here"))
        let there = await Analyzer().analyze(files: try makeCheckout(named: "there"))
        #expect(!here.findings.isEmpty)
        #expect(here.findings.map(\.fingerprint) == there.findings.map(\.fingerprint))
        // ...even though the displayed paths differ.
        #expect(here.findings[0].path != there.findings[0].path)
    }

    @Test("Fingerprints hash the repository-relative path")
    func anchoredToRepositoryRoot() async throws {
        let files = try makeCheckout(named: "anchor")
        let report = await Analyzer().analyze(files: files)
        let finding = try #require(report.findings.first)
        #expect(finding.fingerprintPath == "Holder.swift")
    }

    @Test("Outside a repository, the absolute path is hashed as before")
    func fallsBackOutsideRepository() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcleak-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Holder.swift")
        try "final class C { var h: (() -> Void)?; func s() { h = { self.f() } }; func f() {} }"
            .write(to: file, atomically: true, encoding: .utf8)
        let report = await Analyzer().analyze(files: [file.path])
        #expect(report.findings.allSatisfy { $0.fingerprintPath == nil })
    }
}
