#if canImport(NaturalLanguage)
    import Foundation

    /// Produces dense vector embeddings of short code snippets. arcleak uses them
    /// only to *group/order* findings of similar shape in the report (experimental
    /// `--experimental-embedding-rank`) — never to decide which findings fire.
    ///
    /// Two providers ship, both zero-download and dependency-free (no
    /// HuggingFace / Core ML / tokenizer bundles):
    /// - ``NLContextualSemanticEmbeddingProvider`` — Apple's `NLContextualEmbedding`
    ///   (macOS 14+), a real semantically-grounded embedding, the default.
    /// - ``DeterministicEmbeddingProvider`` — an FNV n-gram hash fallback used when
    ///   the NL asset is unavailable (offline / sandbox) so ranking still runs.
    public protocol SemanticEmbeddingProvider: Sendable {
        /// Dimension of every embedding this provider returns. Callers validate
        /// dimension equality before computing similarity.
        var embeddingDimension: Int { get }

        /// Embed a code snippet into a dense vector.
        func embed(snippet: String) async throws -> [Float]

        /// Batch embedding for throughput. The default runs `embed(snippet:)`
        /// serially.
        func embed(snippets: [String]) async throws -> [[Float]]
    }

    extension SemanticEmbeddingProvider {
        public func embed(snippets: [String]) async throws -> [[Float]] {
            var results: [[Float]] = []
            results.reserveCapacity(snippets.count)
            for snippet in snippets {
                results.append(try await embed(snippet: snippet))
            }
            return results
        }
    }

    public enum SemanticEmbeddingError: Error, Sendable, CustomStringConvertible {
        case notConfigured
        case snippetTooLong(actual: Int, limit: Int)
        case modelLoadFailed(underlying: any Error)
        case inferenceFailed(reason: String)

        public var description: String {
            switch self {
            case .notConfigured:
                "Semantic embedding provider not configured."
            case .snippetTooLong(let actual, let limit):
                "Code snippet of \(actual) tokens exceeds the embedding context window (\(limit))."
            case .modelLoadFailed(let underlying):
                "Failed to load embedding model: \(underlying.localizedDescription)"
            case .inferenceFailed(let reason):
                "Embedding inference failed: \(reason)"
            }
        }
    }

    /// Default provider for builds/hosts with no usable embedding model: every
    /// call throws `.notConfigured` so callers degrade explicitly rather than
    /// silently.
    public struct UnconfiguredSemanticEmbeddingProvider: SemanticEmbeddingProvider, Sendable {
        public init() {}

        public var embeddingDimension: Int { 0 }

        public func embed(snippet: String) async throws -> [Float] {
            throw SemanticEmbeddingError.notConfigured
        }

        public func embed(snippets: [String]) async throws -> [[Float]] {
            throw SemanticEmbeddingError.notConfigured
        }
    }
#endif
