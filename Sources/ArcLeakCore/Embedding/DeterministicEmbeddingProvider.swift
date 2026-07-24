#if canImport(NaturalLanguage)
    import Foundation

    /// A deterministic, dependency-free embedding provider: the fallback used
    /// when `NLContextualEmbedding` assets are unavailable (offline / sandbox),
    /// and the substrate for tests.
    ///
    /// Produces a stable `[Float]` vector by hashing character n-grams into
    /// bucketed counts (FNV-1a). NOT semantically meaningful — code that differs
    /// only by renamed identifiers hashes to distinct buckets — but it is stable
    /// and cheap, so shape-similar snippets still cluster.
    public struct DeterministicEmbeddingProvider: SemanticEmbeddingProvider {
        public init(dimension: Int = 128, ngramSize: Int = 3) {
            precondition(dimension > 0, "dimension must be > 0")
            precondition(ngramSize > 0, "ngramSize must be > 0")
            self.embeddingDimension = dimension
            self.ngramSize = ngramSize
        }

        public let embeddingDimension: Int
        public let ngramSize: Int

        public func embed(snippet: String) async throws -> [Float] {
            var buckets = [Float](repeating: 0, count: embeddingDimension)
            let scalars = Array(snippet.unicodeScalars)
            guard scalars.count >= ngramSize else { return buckets }

            for start in 0...(scalars.count - ngramSize) {
                var hash: UInt64 = 0xCBF2_9CE4_8422_2325  // FNV-1a offset basis
                for offset in 0..<ngramSize {
                    hash ^= UInt64(scalars[start + offset].value)
                    hash = hash &* 0x0000_0100_0000_01B3  // FNV-1a prime
                }
                let bucket = Int(hash % UInt64(embeddingDimension))
                buckets[bucket] += 1
            }
            return buckets
        }
    }
#endif
