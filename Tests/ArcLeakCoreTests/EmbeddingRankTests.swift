#if canImport(NaturalLanguage)
    import ArcLeakCore
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
    }
#endif
