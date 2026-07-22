import ArcLeakCore
import Foundation
import Testing

/// The index seam, proven against a fake backend before the real one exists:
/// external-type upgrades unlock reference-type-gated rules, absence degrades
/// to silence, and store discovery honors the staleness contract.
@Suite struct IndexSeamTests {
    struct FakeIndex: IndexReading {
        let types: [String: ExternalTypeFacts]
        func externalTypeFacts(name: String) -> ExternalTypeFacts? { types[name] }
    }

    @Test("Without an index, extensions of unknown types stay silent — never guessed")
    func degradesToSilence() {
        // `handler` isn't resolvable as a member either, so build the stronger
        // variant: self.handler assignment inside the external extension.
        let source = """
            extension ImportedController {
                func arm() {
                    self.onChange = { self.fire() }
                }
            }
            """
        #expect(Analyzer().analyze(source: source, path: "ext.swift").findings.isEmpty)
    }

    @Test("A fake index upgrade unlocks the stored-closure rule in the extension")
    func indexUnlocksRule() {
        let source = """
            extension ImportedController {
                func arm() {
                    self.onChange = { self.fire() }
                }
            }
            """
        let index = FakeIndex(types: [
            "ImportedController": ExternalTypeFacts(isReferenceType: true)
        ])
        let findings = Analyzer()
            .analyze(source: source, path: "ext.swift", index: index).findings
        #expect(findings.map(\.rule) == [.storedClosureStrongSelf])
    }

    @Test("Index saying value-type keeps the gate closed")
    func valueTypeStaysSilent() {
        let index = FakeIndex(types: [
            "ImportedController": ExternalTypeFacts(isReferenceType: false)
        ])
        let source = """
            extension ImportedController {
                func arm() {
                    self.onChange = { self.fire() }
                }
            }
            """
        #expect(
            Analyzer().analyze(source: source, path: "ext.swift", index: index).findings.isEmpty
        )
    }

    @Test("Store discovery finds .build/index-build and reports staleness")
    func locatorAndStaleness() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-index-\(UUID().uuidString)")
        let store = root.appending(path: ".build/index-build")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)

        let discovered = try #require(IndexStoreLocator.discover(projectRoot: root))
        #expect(discovered.url.path.hasSuffix(".build/index-build"))

        let future = discovered.modificationDate.addingTimeInterval(3600)
        #expect(discovered.isStale(comparedTo: future))
        let past = discovered.modificationDate.addingTimeInterval(-3600)
        #expect(!discovered.isStale(comparedTo: past))

        #expect(IndexStoreLocator.discover(projectRoot: root.appending(path: "missing")) == nil)
    }
}
