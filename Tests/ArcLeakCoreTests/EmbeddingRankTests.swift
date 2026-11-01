import ProjectModel

#if canImport(NaturalLanguage)
    import ArcLeakCore
    import Foundation
    import SemanticEmbedding
    import Testing

    /// The experimental embedding-rank ranker: shape-similar findings cluster
    /// together (proven with the deterministic provider on controlled snippets),
    /// the finding set is never changed, and it fails open.
    @Suite struct EmbeddingRankTests {
        /// A provider whose every call fails, as one with a broken model would.
        private struct ThrowingProvider: SemanticEmbeddingProvider {
            struct Failure: Error {}
            var embeddingDimension: Int { 0 }
            func embed(snippet: String) async throws -> [Float] { throw Failure() }
        }

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
                findings: findings,
                snippets: ["only one"],
                provider: DeterministicEmbeddingProvider()
            )
            #expect(ranked.map(\.line) == [1, 2])
        }

        @Test("A throwing provider fails open — original order preserved")
        func failsOpenOnProviderError() async {
            let findings = [finding(line: 1), finding(line: 2), finding(line: 3)]
            let ranked = await EmbeddingRank.reorder(
                findings: findings,
                snippets: ["a", "b", "c"],
                provider: ThrowingProvider()
            )
            #expect(ranked.map(\.line) == [1, 2, 3])
        }

        @Test("Every provider names itself, so a run can say which model ranked it")
        func providersAreNamed() {
            #expect(DeterministicEmbeddingProvider().providerName == "deterministic (n-gram hash, fallback)")
            #expect(ThrowingProvider().providerName == "embedding")
        }
    }

    #if canImport(CoreML)
        /// Which provider a run resolves. The search for a bundle next to the executable is analyzerkit's
        /// (`EmbeddingBundleLocator`, tested there).
        @Suite struct BundleResolutionTests {
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
            static let miniLMBundle = "/Users/me/Developer/ongoing/swift/SwiftStaticAnalysis/Models/MiniLM"

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
