import ArcLeakCore
import Foundation
import Testing

/// Index-backed cross-module resolution proven at the ownership-graph level
/// against a fake index (deterministic, no real store): a strong property
/// pointing at a class in another module completes a cycle ONLY when the index
/// confirms class-ness and supplies the back-reference — never a guess — and
/// the same corpus stays silent without it. Plus the graceful-fallback front
/// door. The IndexStoreDB backend itself is exercised in `IndexStoreBackendTests`.
@Suite struct IndexCrossModuleTests {
    struct FakeIndex: IndexReading {
        let types: [String: ExternalTypeFacts]
        func externalTypeFacts(name: String) -> ExternalTypeFacts? { types[name] }
    }

    /// `Hub` (in the analyzed corpus) holds a strong `Plugin` — but `Plugin` is
    /// declared outside the analyzed file set.
    private let hubSource = """
        class Hub {
            var plugin: Plugin?
        }
        """

    private func pluginToHub() -> ExternalStrongReference {
        ExternalStrongReference(
            property: "hub",
            referencedTypeNames: ["Hub"],
            position: SourcePosition(line: 2, column: 5)
        )
    }

    @Test("Index confirming a class in another module closes the cross-module cycle")
    func indexClosesCrossModuleCycle() {
        let index = FakeIndex(types: [
            "Plugin": ExternalTypeFacts(
                isReferenceType: true,
                strongReferences: [pluginToHub()],
                declaringPath: "Plugin.swift"
            )
        ])
        let findings = Analyzer().analyze(source: hubSource, path: "Hub.swift", index: index).findings
        #expect(findings.map(\.rule) == [.mutualStrongProperties])
    }

    @Test("Without an index the same corpus stays silent — the index uniquely unlocks it")
    func defaultModeStaysSilent() {
        #expect(Analyzer().analyze(source: hubSource, path: "Hub.swift").findings.isEmpty)
    }

    @Test("A confirmed value type never completes a cycle")
    func valueTypeStaysSilent() {
        let index = FakeIndex(types: [
            "Plugin": ExternalTypeFacts(isReferenceType: false, strongReferences: [pluginToHub()])
        ])
        #expect(Analyzer().analyze(source: hubSource, path: "Hub.swift", index: index).findings.isEmpty)
    }

    @Test("A confirmed class with no back-reference is a chain, not a cycle")
    func chainWithoutBackReferenceStaysSilent() {
        let index = FakeIndex(types: [
            "Plugin": ExternalTypeFacts(
                isReferenceType: true, strongReferences: [], declaringPath: "Plugin.swift"
            )
        ])
        #expect(Analyzer().analyze(source: hubSource, path: "Hub.swift", index: index).findings.isEmpty)
    }

    @Test("An index that doesn't know the type resolves nothing — conservative")
    func unknownTypeStaysSilent() {
        let index = FakeIndex(types: [:])
        #expect(Analyzer().analyze(source: hubSource, path: "Hub.swift", index: index).findings.isEmpty)
    }

    @Test("A three-module strong chain still closes across external nodes")
    func transitiveCrossModuleCycle() {
        // Hub (corpus) → A → B → Hub, with A and B both external.
        let index = FakeIndex(types: [
            "A": ExternalTypeFacts(
                isReferenceType: true,
                strongReferences: [
                    ExternalStrongReference(
                        property: "b", referencedTypeNames: ["B"],
                        position: SourcePosition(line: 1, column: 1)
                    )
                ],
                declaringPath: "A.swift"
            ),
            "B": ExternalTypeFacts(
                isReferenceType: true,
                strongReferences: [
                    ExternalStrongReference(
                        property: "hub", referencedTypeNames: ["Hub"],
                        position: SourcePosition(line: 1, column: 1)
                    )
                ],
                declaringPath: "B.swift"
            ),
        ])
        let source = """
            class Hub {
                var a: A?
            }
            """
        let findings = Analyzer().analyze(source: source, path: "Hub.swift", index: index).findings
        #expect(findings.map(\.rule) == [.mutualStrongProperties])
    }

    @Test("Graceful fallback: --index-store with no store yields no index and a clear note")
    func gracefulFallbackNote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-noindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await IndexStoreResolution.resolve(
            projectRoot: root.path,
            explicitStorePath: nil,
            autoBuild: false,
            analyzedFiles: [],
            defines: []
        )
        #expect(outcome.index == nil)
        #expect(outcome.note != nil)
    }
}
