#if canImport(NaturalLanguage)
    public import Foundation

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
                            bundleDir: URL(fileURLWithPath: bundlePath)
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

                if let bundledDir = bundledModelDirectory(),
                    let provider = try? await HFSemanticEmbeddingProvider(bundleDir: bundledDir)
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
            if #available(macOS 14.0, *) {
                if let contextual = try? NLContextualSemanticEmbeddingProvider() {
                    return contextual
                }
            }
            return DeterministicEmbeddingProvider()
        }

        #if canImport(CoreML)
            /// Locates a Core ML embedding bundle shipped alongside the executable,
            /// so a distribution that bundles a model uses it with no flag.
            /// `ARCLEAK_EMBEDDING_BUNDLE` overrides the location for installs that
            /// separate the binary from its resources (`bin/` + `share/`).
            ///
            /// Returns nil for the ordinary case — a plain `arcleak` binary, and
            /// every dev/test build, ships no model — which leaves the on-device
            /// `NLContextualEmbedding` default in charge.
            public static func bundledModelDirectory() -> URL? {
                let executableURL =
                    (Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ToolInfo.name))
                    .resolvingSymlinksInPath()
                return bundledModelDirectory(
                    executableDir: executableURL.deletingLastPathComponent(),
                    override: ProcessInfo.processInfo.environment["ARCLEAK_EMBEDDING_BUNDLE"]
                )
            }

            /// Pure candidate search behind ``bundledModelDirectory()`` — no process
            /// globals, so it is unit-testable. Search order: `override` (the
            /// `ARCLEAK_EMBEDDING_BUNDLE` value) → `<executableDir>/Models/MiniLM` →
            /// `<executableDir>/../share/arcleak/Models/MiniLM` (FHS / Homebrew
            /// layout). The first candidate containing a `.mlpackage`/`.mlmodelc`
            /// wins; nil when none do.
            public static func bundledModelDirectory(executableDir: URL, override: String?) -> URL? {
                let manager = FileManager.default
                func hasModel(_ directory: URL) -> Bool {
                    guard
                        let contents = try? manager.contentsOfDirectory(
                            at: directory,
                            includingPropertiesForKeys: nil
                        )
                    else { return false }
                    return contents.contains {
                        $0.pathExtension == "mlpackage" || $0.pathExtension == "mlmodelc"
                    }
                }

                var candidates: [URL] = []
                if let override, !override.isEmpty {
                    candidates.append(URL(fileURLWithPath: override))
                }
                candidates.append(executableDir.appendingPathComponent("Models/MiniLM"))
                candidates.append(
                    executableDir.deletingLastPathComponent()
                        .appendingPathComponent("share/\(ToolInfo.name)/Models/MiniLM")
                )

                // Resolve each candidate so a symlinked model directory reaches the
                // provider as its real path: `contentsOfDirectory` (here, and in the
                // provider's own model lookup) does not traverse a URL that is
                // itself a symlink to a directory, so an unresolved candidate reads
                // as "no model" and discovery silently misses it.
                return candidates.map { $0.resolvingSymlinksInPath() }.first(where: hasModel)
            }
        #endif

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
