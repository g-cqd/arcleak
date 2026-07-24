#if canImport(NaturalLanguage)
    import Foundation
    public import NaturalLanguage

    /// A real ``SemanticEmbeddingProvider`` backed by Apple's
    /// `NLContextualEmbedding` (macOS 14+). Produces dense, contextual,
    /// sentence-level embeddings without shipping a model bundle — the NL
    /// framework's English contextual-embedding asset is system-provided. Token
    /// vectors are mean-pooled to a single fixed-dimension vector per snippet.
    ///
    /// This is not trained on code, but it is a real, semantically-grounded
    /// embedding (not the FNV hash of ``DeterministicEmbeddingProvider``), so it
    /// groups findings whose flagged sites read similarly. If the asset is not
    /// present and cannot be loaded (offline / sandbox), `init` throws and the
    /// caller falls back to the deterministic provider.
    @available(macOS 14.0, *)
    public struct NLContextualSemanticEmbeddingProvider: SemanticEmbeddingProvider {
        /// Dimension of every embedding this provider returns.
        public let embeddingDimension: Int
        /// Language the underlying contextual embedding was trained on.
        public let language: NLLanguage

        /// Loads the contextual-embedding asset eagerly so a later
        /// `embed(snippet:)` failure surfaces here at construction time.
        public init(language: NLLanguage = .english) throws {
            guard let probe = NLContextualEmbedding(language: language) else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NLContextualEmbeddingError.unsupportedLanguage(language)
                )
            }
            if !probe.hasAvailableAssets {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NLContextualEmbeddingError.assetsUnavailable
                )
            }
            do {
                try probe.load()
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }
            self.embeddingDimension = probe.dimension
            self.language = language
        }

        public func embed(snippet: String) async throws -> [Float] {
            guard let embedding = NLContextualEmbedding(language: language) else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NLContextualEmbeddingError.unsupportedLanguage(language)
                )
            }
            do {
                try embedding.load()
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }

            let result: NLContextualEmbeddingResult
            do {
                result = try embedding.embeddingResult(for: snippet, language: language)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(reason: error.localizedDescription)
            }

            let dimension = embedding.dimension
            var pooled = [Float](repeating: 0, count: dimension)
            var tokenCount = 0
            result.enumerateTokenVectors(in: snippet.startIndex..<snippet.endIndex) { vector, _ in
                guard vector.count == dimension else { return true }
                for index in 0..<dimension {
                    pooled[index] += Float(vector[index])
                }
                tokenCount += 1
                return true
            }

            if tokenCount > 0 {
                let scale = 1.0 / Float(tokenCount)
                for index in 0..<dimension {
                    pooled[index] *= scale
                }
            }
            return pooled
        }
    }

    /// Provider-local error reasons, wrapped by
    /// ``SemanticEmbeddingError/modelLoadFailed(underlying:)``.
    public enum NLContextualEmbeddingError: Error, CustomStringConvertible {
        case unsupportedLanguage(NLLanguage)
        case assetsUnavailable

        public var description: String {
            switch self {
            case .unsupportedLanguage(let language):
                "NLContextualEmbedding does not support language: \(language.rawValue)"
            case .assetsUnavailable:
                "NLContextualEmbedding assets are not available locally."
            }
        }
    }
#endif
