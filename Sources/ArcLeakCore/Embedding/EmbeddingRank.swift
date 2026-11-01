#if canImport(NaturalLanguage)
    import Foundation
    public import SemanticEmbedding

    /// Experimental, purely presentational: groups findings whose flagged-site
    /// snippets read similarly so repeated-shape findings appear together in the
    /// report. It reorders findings — it NEVER changes which findings fire, their
    /// severity, or the exit code. Deterministic (greedy, first-appearance
    /// order) and fails open: any embedding error returns the input untouched.
    public enum EmbeddingRank {
        /// Cosine-similarity threshold above which two findings join a cluster.
        public static let similarityThreshold: Float = 0.82

        // MARK: - Provider selection

        /// The provider that will run, plus an optional note explaining a
        /// fallback. Mirrors ``IndexStoreResolution/Outcome``: resolution never
        /// throws, because a missing or broken model must degrade the *quality* of
        /// an ordering, never fail an analysis.
        public struct ProviderResolution: Sendable {
            public let provider: any SemanticEmbeddingProvider
            /// Non-nil only when something the user asked for did not happen.
            public let note: String?

            public init(provider: any SemanticEmbeddingProvider, note: String? = nil) {
                self.provider = provider
                self.note = note
            }
        }

        /// Full provider resolution, in preference order:
        /// explicit `--embedding-bundle` → a model shipped next to the executable
        /// → `NLContextualEmbedding` → the deterministic fallback.
        ///
        /// Async because loading a Core ML bundle is (compiling an `.mlpackage` on
        /// first use, reading the tokenizer). Only the first two steps need it, so
        /// ``defaultProvider()`` stays synchronous for callers that want just the
        /// zero-download tail.
        ///
        /// A bundle that fails to load never fails the run: an *explicit* bundle
        /// falls through with a note (the user asked for it, so silence would be
        /// wrong), an auto-discovered one falls through silently (it is an upgrade
        /// nobody requested).
        public static func resolveProvider(bundlePath: String? = nil) async -> ProviderResolution {
            // Unreachable on a platform with NaturalLanguage but no CoreML — no
            // such Apple platform exists — but the gate keeps this file honest
            // about which half of the feature needs which framework.
            #if canImport(CoreML)
                if let bundlePath, !bundlePath.isEmpty {
                    do {
                        let provider = try await HFSemanticEmbeddingProvider(
                            bundleDir: URL(fileURLWithPath: bundlePath),
                            maxLength: bundleMaxLength
                        )
                        return ProviderResolution(provider: provider)
                    } catch {
                        return ProviderResolution(
                            provider: defaultProvider(),
                            note:
                                "--embedding-bundle at \(bundlePath) could not be loaded (\(error)); "
                                + "ranking with the on-device default instead"
                        )
                    }
                }

                if let bundledDir = EmbeddingBundleLocator.directory(tool: ToolInfo.name),
                    let provider = try? await HFSemanticEmbeddingProvider(
                        bundleDir: bundledDir,
                        maxLength: bundleMaxLength
                    )
                {
                    return ProviderResolution(provider: provider)
                }
            #endif

            return ProviderResolution(provider: defaultProvider())
        }

        /// The zero-download provider: `NLContextualEmbedding` when its system
        /// asset is available, else the deterministic FNV fallback — so ranking
        /// always runs, offline, with nothing to install.
        public static func defaultProvider() -> any SemanticEmbeddingProvider {
            SemanticEmbeddingProviders.onDeviceOrFallback()
        }

        /// Cap on post-tokenization sequence length for a bundle's model: the
        /// MiniLM-class context window, and a safe ceiling for fixed-shape
        /// exports whose `[1, 128]` input a longer sequence overflows.
        private static let bundleMaxLength = 128

        // MARK: - Ranking

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
