#if canImport(NaturalLanguage)
    import Foundation

    /// Experimental, purely presentational: groups findings whose flagged-site
    /// snippets read similarly so repeated-shape findings appear together in the
    /// report. It reorders findings — it NEVER changes which findings fire, their
    /// severity, or the exit code. Deterministic (greedy, first-appearance
    /// order) and fails open: any embedding error returns the input untouched.
    public enum EmbeddingRank {
        /// Cosine-similarity threshold above which two findings join a cluster.
        public static let similarityThreshold: Float = 0.82

        /// The default provider: `NLContextualEmbedding` when its system asset is
        /// available, else the deterministic FNV fallback — so ranking always
        /// runs with zero download.
        public static func defaultProvider() -> any SemanticEmbeddingProvider {
            if #available(macOS 14.0, *) {
                if let contextual = try? NLContextualSemanticEmbeddingProvider() {
                    return contextual
                }
            }
            return DeterministicEmbeddingProvider()
        }

        /// Reorder `findings` so shape-similar ones are adjacent. `snippets` is
        /// the flagged-site source text per finding (same order/count). Returns
        /// the input order unchanged on any mismatch or embedding failure.
        public static func reorder(
            findings: [Finding],
            snippets: [String],
            provider: any SemanticEmbeddingProvider
        ) async -> [Finding] {
            guard findings.count > 1, snippets.count == findings.count else { return findings }

            let vectors: [[Float]]
            do {
                vectors = try await provider.embed(snippets: snippets)
            } catch {
                return findings  // fail open
            }
            guard vectors.count == findings.count else { return findings }

            struct Cluster {
                let representative: [Float]
                var members: [Int]
            }
            var clusters: [Cluster] = []
            for (index, vector) in vectors.enumerated() {
                var joined = false
                for position in clusters.indices
                where cosineSimilarity(vector, clusters[position].representative) >= similarityThreshold {
                    clusters[position].members.append(index)
                    joined = true
                    break
                }
                if !joined {
                    clusters.append(Cluster(representative: vector, members: [index]))
                }
            }

            var ordered: [Finding] = []
            ordered.reserveCapacity(findings.count)
            for cluster in clusters {
                for index in cluster.members {
                    ordered.append(findings[index])
                }
            }
            return ordered
        }

        static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
            guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
            var dot: Float = 0
            var normLhs: Float = 0
            var normRhs: Float = 0
            for index in lhs.indices {
                dot += lhs[index] * rhs[index]
                normLhs += lhs[index] * lhs[index]
                normRhs += rhs[index] * rhs[index]
            }
            let denominator = normLhs.squareRoot() * normRhs.squareRoot()
            return denominator > 0 ? dot / denominator : 0
        }
    }
#endif
