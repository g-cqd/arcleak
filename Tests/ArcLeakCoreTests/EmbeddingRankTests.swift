#if canImport(NaturalLanguage)
    import ArcLeakCore
    import Foundation
    import Testing

    /// The experimental embedding-rank ranker: shape-similar findings cluster
    /// together (proven with the deterministic provider on controlled snippets),
    /// the finding set is never changed, and it fails open.
    @Suite struct EmbeddingRankTests {
        private func finding(line: Int) -> Finding {
            Finding(
                rule: .storedClosureStrongSelf,
                severity: .error,
                path: "F.swift",
                line: line,
                column: 1,
                message: "m\(line)"
            )
        }

        @Test("Similar findings are pulled adjacent; the set is unchanged")
        func groupsSimilarFindings() async {
            // f0/f2 identical, f1/f3 identical but disjoint from f0 — so a
            // line-ordered [f0,f1,f2,f3] regroups to [f0,f2,f1,f3].
            let findings = [finding(line: 1), finding(line: 2), finding(line: 3), finding(line: 4)]
            let snippets = ["AAAA AAAA AAAA", "zzzz zzzz zzzz", "AAAA AAAA AAAA", "zzzz zzzz zzzz"]

            let ranked = await EmbeddingRank.reorder(
                findings: findings,
                snippets: snippets,
                provider: DeterministicEmbeddingProvider()
            )

            #expect(ranked.map(\.line) == [1, 3, 2, 4])
            #expect(Set(ranked.map(\.line)) == Set(findings.map(\.line)))
        }

        @Test("A mismatched snippet count leaves the order untouched")
        func mismatchedCountIsIdentity() async {
            let findings = [finding(line: 1), finding(line: 2)]
            let ranked = await EmbeddingRank.reorder(
                findings: findings, snippets: ["only one"], provider: DeterministicEmbeddingProvider()
            )
            #expect(ranked.map(\.line) == [1, 2])
        }

        @Test("A throwing provider fails open — original order preserved")
        func failsOpenOnProviderError() async {
            let findings = [finding(line: 1), finding(line: 2), finding(line: 3)]
            let ranked = await EmbeddingRank.reorder(
                findings: findings,
                snippets: ["a", "b", "c"],
                provider: UnconfiguredSemanticEmbeddingProvider()
            )
            #expect(ranked.map(\.line) == [1, 2, 3])
        }

        @Test("Every provider names itself, so a run can say which model ranked it")
        func providersAreNamed() {
            #expect(DeterministicEmbeddingProvider().providerName == "deterministic (n-gram hash, fallback)")
            #expect(UnconfiguredSemanticEmbeddingProvider().providerName == "embedding")
        }
    }

    #if canImport(CoreML)
        /// Auto-discovery of an executable-adjacent Core ML bundle. These exercise
        /// the pure `bundledModelDirectory(executableDir:override:)` overload with
        /// dummy `.mlmodelc` directories: precedence is what can regress, and it is
        /// decided entirely by path search, so nothing here loads Core ML or
        /// mutates the environment.
        @Suite struct BundledModelDiscoveryTests {
            /// A throwaway tree with an optional model directory at each interesting
            /// location. Returns the root; the caller removes it.
            private static func stage(
                adjacentModel: Bool = false,
                shareModel: Bool = false,
                overrideModel: Bool = false
            ) throws -> (root: URL, execDir: URL, overrideDir: URL) {
                let manager = FileManager.default
                let root = manager.temporaryDirectory.appending(path: "arcleak-discovery-\(UUID().uuidString)")
                let execDir = root.appending(path: "bin")
                let overrideDir = root.appending(path: "custom")
                try manager.createDirectory(at: execDir, withIntermediateDirectories: true)
                func plantModel(in directory: URL) throws {
                    try manager.createDirectory(
                        at: directory.appending(path: "Model.mlmodelc"),
                        withIntermediateDirectories: true
                    )
                }
                if adjacentModel { try plantModel(in: execDir.appending(path: "Models/MiniLM")) }
                if shareModel { try plantModel(in: root.appending(path: "share/arcleak/Models/MiniLM")) }
                if overrideModel { try plantModel(in: overrideDir) }
                return (root, execDir, overrideDir)
            }

            @Test("Discovers a model in Models/MiniLM next to the executable")
            func findsAdjacentModel() throws {
                let (root, execDir, _) = try Self.stage(adjacentModel: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let found = EmbeddingRank.bundledModelDirectory(executableDir: execDir, override: nil)
                #expect(
                    found?.resolvingSymlinksInPath().path
                        == execDir.appending(path: "Models/MiniLM").resolvingSymlinksInPath().path
                )
            }

            @Test("Falls back to the FHS-style share/arcleak layout")
            func findsShareLayoutModel() throws {
                let (root, execDir, _) = try Self.stage(shareModel: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let found = EmbeddingRank.bundledModelDirectory(executableDir: execDir, override: nil)
                let expected = root.appending(path: "share/arcleak/Models/MiniLM").resolvingSymlinksInPath().path
                #expect(found?.resolvingSymlinksInPath().path == expected)
            }

            @Test("ARCLEAK_EMBEDDING_BUNDLE override wins over an adjacent model")
            func overrideTakesPrecedence() throws {
                let (root, execDir, overrideDir) = try Self.stage(adjacentModel: true, overrideModel: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let found = EmbeddingRank.bundledModelDirectory(
                    executableDir: execDir,
                    override: overrideDir.path
                )
                #expect(found?.resolvingSymlinksInPath().path == overrideDir.resolvingSymlinksInPath().path)
            }

            @Test("No model anywhere returns nil (the plain arcleak binary)")
            func noModelReturnsNil() throws {
                let (root, execDir, _) = try Self.stage()
                defer { try? FileManager.default.removeItem(at: root) }
                #expect(EmbeddingRank.bundledModelDirectory(executableDir: execDir, override: nil) == nil)
                // An override pointing at a model-free directory is nil, not a crash.
                #expect(EmbeddingRank.bundledModelDirectory(executableDir: execDir, override: root.path) == nil)
            }

            @Test("An unloadable --embedding-bundle falls through to the default, with a note")
            func badBundleFallsThroughWithNote() async {
                let resolution = await EmbeddingRank.resolveProvider(bundlePath: "/nonexistent/arcleak/model")
                #expect(resolution.note != nil)
                #expect(!resolution.provider.providerName.hasPrefix("bundle:"))
            }
        }

        // MARK: - HF / Core ML bundle provider (local-only, models are gitignored)

        @Suite struct BundledEmbeddingProviderTests {
            /// A code-trained MiniLM Core ML + tokenizer bundle, present only on the
            /// author's machine (models are not committed). Absent in CI → skipped.
            static let miniLMBundle = "/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Models/MiniLM"

            static var bundleAvailable: Bool {
                FileManager.default.fileExists(atPath: miniLMBundle)
            }

            @Test(
                "A MiniLM bundle loads, names itself, and embeds at its config'd width",
                .enabled(if: BundledEmbeddingProviderTests.bundleAvailable)
            )
            func loadsAndEmbeds() async throws {
                let resolution = await EmbeddingRank.resolveProvider(bundlePath: Self.miniLMBundle)
                #expect(resolution.note == nil)
                #expect(resolution.provider.providerName == "bundle:MiniLM")
                // all-MiniLM-L6-v2: hidden_size 384, read from the bundle's config.json.
                #expect(resolution.provider.embeddingDimension == 384)

                let vector = try await resolution.provider.embed(snippet: "self.handler = { self.reload() }")
                #expect(vector.count == 384)
                #expect(vector.contains { $0 != 0 })
            }

            @Test(
                "Ranking with the bundle keeps the finding set identical",
                .enabled(if: BundledEmbeddingProviderTests.bundleAvailable)
            )
            func rankingPreservesTheFindingSet() async throws {
                let findings = (1...4).map {
                    Finding(
                        rule: .storedClosureStrongSelf,
                        severity: .error,
                        path: "F.swift",
                        line: $0,
                        column: 1,
                        message: "m\($0)"
                    )
                }
                let snippets = [
                    "self.handler = { self.reload() }",
                    "timer = Timer.scheduledTimer { self.tick() }",
                    "self.onDone = { self.finish() }",
                    "timer = Timer.scheduledTimer { self.poll() }",
                ]
                let resolution = await EmbeddingRank.resolveProvider(bundlePath: Self.miniLMBundle)
                let ranked = await EmbeddingRank.reorder(
                    findings: findings,
                    snippets: snippets,
                    provider: resolution.provider
                )
                #expect(Set(ranked.map(\.line)) == Set(findings.map(\.line)))
                #expect(ranked.count == findings.count)
            }
        }
    #endif
#endif
