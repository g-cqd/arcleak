#if canImport(CoreML)
    import CoreML
    public import Foundation

    /// A ``SemanticEmbeddingProvider`` backed by a Core ML model plus the
    /// tokenizer it was trained with — WordPiece or byte-level BPE, both built in
    /// rather than pulled from `swift-transformers` (those files document why;
    /// `WordPieceParityTests` and `BPEParityTests` pin them token-for-token
    /// against it). See ``BundleTokenizer`` for selection. Selected by
    /// `--embedding-bundle <dir>`, or auto-discovered next to the executable
    /// (see ``EmbeddingRank/bundledModelDirectory()``).
    ///
    /// Why bother, when arcleak already embeds with zero download? Because both
    /// zero-download providers are the wrong tool for source lines. Apple's
    /// `NLContextualEmbedding` is an *English* model: it reads code as prose, so
    /// it over-clusters — everything that "looks like a statement" lands in one
    /// cone of the vector space. A code-trained sentence model (all-MiniLM-L6-v2
    /// and friends) is both tighter and, being far smaller, several times faster.
    /// Ranking is presentational, so this only ever changes grouping quality — the
    /// finding set and exit code are identical either way.
    ///
    /// `bundleDir` holds both halves of the model: the Core ML bundle
    /// (`.mlpackage`, compiled on first use, or a prebuilt `.mlmodelc`) and its
    /// tokenizer files (`vocab.txt` / `vocab.json` + `merges.txt` /
    /// `tokenizer.json`). This covers both families that matter for code:
    /// WordPiece (all-MiniLM-L6-v2, BGE) and byte-level BPE (CodeBERT,
    /// GraphCodeBERT). A SentencePiece/Unigram bundle fails to load rather than
    /// tokenizing wrongly, and the caller falls back to the zero-download provider.
    public final class HFSemanticEmbeddingProvider: SemanticEmbeddingProvider, @unchecked Sendable {
        public let embeddingDimension: Int
        public let providerName: String

        /// - Parameters:
        ///   - bundleDir: directory holding both the Core ML bundle and the HF
        ///     tokenizer files.
        ///   - modelURL: explicit model-bundle override; when `nil` the provider
        ///     picks the first `.mlpackage` / `.mlmodelc` in `bundleDir`.
        ///   - maxLength: cap on post-tokenization sequence length.
        ///   - inputIDsName / attentionMaskName / tokenTypeIDsName /
        ///     positionIDsName: model input feature names (the optional two are fed
        ///     only when the model actually declares them).
        ///   - lastHiddenStateName: per-token output, mean-pooled here.
        public init(
            bundleDir: URL,
            modelURL: URL? = nil,
            maxLength: Int = 128,
            inputIDsName: String = "input_ids",
            attentionMaskName: String = "attention_mask",
            tokenTypeIDsName: String? = "token_type_ids",
            positionIDsName: String? = "position_ids",
            lastHiddenStateName: String = "last_hidden_state"
        ) async throws {
            self.providerName = "bundle:\(bundleDir.lastPathComponent)"
            let resolvedModelURL: URL
            if let modelURL {
                resolvedModelURL = modelURL
            } else if let found = HFSemanticEmbeddingProvider.findModel(in: bundleDir) {
                resolvedModelURL = found
            } else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: HFProviderError.noModel(bundleDir.path)
                )
            }

            let compiledURL: URL
            if resolvedModelURL.pathExtension == "mlmodelc" {
                compiledURL = resolvedModelURL
            } else {
                do {
                    compiledURL = try await MLModel.compileModel(at: resolvedModelURL)
                } catch {
                    throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
                }
            }

            // Deliberately NOT `.all`: these are sequence-length-flexible exports,
            // and a RoBERTa-family model whose output is
            // `hidden_states [batch, sequence, hidden]` is data-dependent, which
            // the Neural Engine runtime refuses. Worse, it refuses at *prediction*
            // time by writing an opaque Espresso "Invalid blob shape" diagnostic
            // straight to **stdout** — corrupting `--format json` for the caller,
            // which no amount of Swift-side error handling can undo (measured:
            // CodeBERT emitted 19 KB of that garbage ahead of the report). Even
            // probing `.all` first is unsafe, because the probe's own failure
            // prints it. The cost is small and bounded — MiniLM ranking over 30
            // findings measured ~0.95 s on `.all` against ~1.35 s here, mostly
            // model load rather than per-prediction — and it buys uncorrupted
            // machine-readable output plus RoBERTa-family bundles working at all.
            // So start at `.cpuAndGPU` and step down only if that cannot run.
            var loaded: MLModel?
            for units in [MLComputeUnits.cpuAndGPU, .cpuOnly] {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                guard let candidate = try? MLModel(contentsOf: compiledURL, configuration: configuration)
                else { continue }
                if HFSemanticEmbeddingProvider.probeSucceeds(
                    candidate, inputIDsName: inputIDsName, attentionMaskName: attentionMaskName,
                    tokenTypeIDsName: tokenTypeIDsName, positionIDsName: positionIDsName)
                {
                    loaded = candidate
                    break
                }
            }
            guard let resolvedModel = loaded else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: HFProviderError.noWorkingComputeUnit(compiledURL.lastPathComponent))
            }
            self.model = resolvedModel

            do {
                self.tokenizer = try BundleTokenizer.make(bundleDir: bundleDir)
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }

            self.maxLength = maxLength
            self.inputIDsName = inputIDsName
            self.attentionMaskName = attentionMaskName
            self.tokenTypeIDsName = tokenTypeIDsName
            self.positionIDsName = positionIDsName

            // Resolve the output name: requested, then the common alternates, then
            // the first declared multi-array output.
            let declaredOutputs = model.modelDescription.outputDescriptionsByName
            if declaredOutputs[lastHiddenStateName] != nil {
                self.lastHiddenStateName = lastHiddenStateName
            } else if declaredOutputs["hidden_states"] != nil {
                self.lastHiddenStateName = "hidden_states"
            } else if declaredOutputs["output"] != nil {
                self.lastHiddenStateName = "output"
            } else if let first = declaredOutputs.first(where: { $0.value.type == .multiArray }) {
                self.lastHiddenStateName = first.key
            } else {
                self.lastHiddenStateName = lastHiddenStateName
            }

            // Which optional inputs does this export actually accept? Feeding one
            // the model does not declare is a hard prediction failure.
            let inputDescriptions = model.modelDescription.inputDescriptionsByName
            let declaredInputs = Set(inputDescriptions.keys)
            self.acceptsTokenTypeIDs = tokenTypeIDsName.map(declaredInputs.contains) ?? false
            self.acceptsPositionIDs = positionIDsName.map(declaredInputs.contains) ?? false

            // Fixed input shape? Fully-baked exports declare `input_ids` as e.g.
            // [1, 128]; dynamic exports use [1, 1] or leave it unconstrained. A
            // fixed length wins over `maxLength`, in both directions: longer
            // sequences overflow the input, shorter ones must be zero-padded.
            if let inputDescription = inputDescriptions[inputIDsName],
                let shape = inputDescription.multiArrayConstraint?.shape,
                shape.count == 2, shape[1].intValue > 1
            {
                self.fixedSequenceLength = shape[1].intValue
            } else {
                self.fixedSequenceLength = nil
            }

            // Embedding dimension: the HF config.json `hidden_size`, else the
            // declared output shape, else the BERT-base default.
            let configURL = bundleDir.appendingPathComponent("config.json")
            if let hiddenSize = HFSemanticEmbeddingProvider.readHiddenSize(from: configURL) {
                self.embeddingDimension = hiddenSize
            } else if let outputDescription = model.modelDescription.outputDescriptionsByName[lastHiddenStateName],
                let shape = outputDescription.multiArrayConstraint?.shape,
                shape.count == 3, shape[2].intValue > 0
            {
                self.embeddingDimension = shape[2].intValue
            } else {
                self.embeddingDimension = HFSemanticEmbeddingProvider.defaultDimensionGuess
            }
        }

        public func embed(snippet: String) async throws -> [Float] {
            // Tokenize with the model's own tokenizer (BPE / WordPiece /
            // SentencePiece plus its special tokens) — a mismatched tokenizer
            // produces vectors that are silently meaningless, not an error.
            var ids = tokenizer.encode(text: snippet)
            let effectiveMax = fixedSequenceLength ?? maxLength
            if ids.count > effectiveMax {
                ids = Array(ids.prefix(effectiveMax))
            }
            let realTokenCount = ids.count
            guard realTokenCount > 0 else {
                throw SemanticEmbeddingError.inferenceFailed(reason: "Tokenizer produced an empty sequence")
            }
            let sequenceLength = fixedSequenceLength ?? realTokenCount

            // Every Int32 input is built through one helper: the attention mask is
            // 1 for real tokens and 0 for padding; ids pad with 0.
            var features: [String: MLFeatureValue] = [
                inputIDsName: MLFeatureValue(
                    multiArray: try MLInt32Input.make(length: sequenceLength) {
                        $0 < realTokenCount ? Int32(ids[$0]) : 0
                    }
                ),
                attentionMaskName: MLFeatureValue(
                    multiArray: try MLInt32Input.make(length: sequenceLength) {
                        $0 < realTokenCount ? 1 : 0
                    }
                ),
            ]
            if acceptsTokenTypeIDs, let name = tokenTypeIDsName {
                features[name] = MLFeatureValue(
                    multiArray: try MLInt32Input.make(length: sequenceLength) { _ in 0 }
                )
            }
            if acceptsPositionIDs, let name = positionIDsName {
                features[name] = MLFeatureValue(
                    multiArray: try MLInt32Input.make(length: sequenceLength) { Int32($0) }
                )
            }

            let output: any MLFeatureProvider
            do {
                let input = try MLDictionaryFeatureProvider(dictionary: features)
                output = try await model.prediction(from: input)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(reason: "\(error)")
            }

            guard let lastHidden = output.featureValue(for: lastHiddenStateName)?.multiArrayValue else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Model output missing '\(lastHiddenStateName)' multi-array"
                )
            }
            return try pool(lastHidden, sequenceLength: sequenceLength, realTokenCount: realTokenCount)
        }

        // MARK: - Private

        private let model: MLModel
        private let tokenizer: any SubwordTokenizing
        private let maxLength: Int
        private let inputIDsName: String
        private let attentionMaskName: String
        private let tokenTypeIDsName: String?
        private let positionIDsName: String?
        private let lastHiddenStateName: String
        private let acceptsTokenTypeIDs: Bool
        private let acceptsPositionIDs: Bool
        private let fixedSequenceLength: Int?
        private static let defaultDimensionGuess = 768

        /// Mean-pool the model output over the real tokens. Accepts a pre-pooled
        /// `(1, D)` output (used as-is) or the per-token `(1, T, D)` shape (averaged
        /// over real tokens, skipping padding). Reads go through `MLMultiArray`'s
        /// element subscript rather than its `dataPointer`, so no unsafe pointer is
        /// taken and `strictMemorySafety` stays satisfied; `.floatValue` converts
        /// whatever numeric dtype the export used.
        private func pool(
            _ lastHidden: MLMultiArray,
            sequenceLength: Int,
            realTokenCount: Int
        ) throws -> [Float] {
            let shape = lastHidden.shape.map(\.intValue)
            if shape.count == 2, shape[0] == 1, shape[1] > 0 {
                let dimension = shape[1]
                var pooled = [Float](repeating: 0, count: dimension)
                for index in 0..<dimension { pooled[index] = lastHidden[index].floatValue }
                return pooled
            }
            guard shape.count == 3, shape[0] == 1, shape[1] == sequenceLength else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Unexpected \(lastHiddenStateName) shape: \(shape) for seqLen=\(sequenceLength)"
                )
            }
            let dimension = shape[2]
            var pooled = [Float](repeating: 0, count: dimension)
            for token in 0..<realTokenCount {
                let base = token * dimension
                for index in 0..<dimension { pooled[index] += lastHidden[base + index].floatValue }
            }
            let scale = 1.0 / Float(realTokenCount)
            for index in 0..<dimension { pooled[index] *= scale }
            return pooled
        }

        /// `.mlpackage` first, then `.mlmodelc`, one level deep in `dir`.
        private static func findModel(in dir: URL) -> URL? {
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil
                )
            else { return nil }
            for url in contents where url.pathExtension == "mlpackage" { return url }
            for url in contents where url.pathExtension == "mlmodelc" { return url }
            return nil
        }

        /// Read `hidden_size` (or T5's `d_model`) from a HuggingFace `config.json`.
        private static func readHiddenSize(from configURL: URL) -> Int? {
            guard let data = try? Data(contentsOf: configURL),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            if let hidden = json["hidden_size"] as? Int { return hidden }
            if let hidden = json["d_model"] as? Int { return hidden }
            return nil
        }
    }

    /// Core ML input construction, factored out so the four inputs above are not
    /// four near-identical `MLMultiArray`-building blocks.
    extension HFSemanticEmbeddingProvider {
        /// Runs one tiny prediction to find out whether `model` can actually
        /// execute on the compute units it was loaded with.
        ///
        /// Necessary because Core ML defers the incompatibility to prediction
        /// time: a model with a sequence-dependent output loads happily on `.all`
        /// and only then fails, printing an Espresso diagnostic to **stdout**
        /// (which would corrupt `--format json`). Four tokens is enough — the
        /// failure is about shape *kind*, not length.
        fileprivate static func probeSucceeds(
            _ model: MLModel,
            inputIDsName: String,
            attentionMaskName: String,
            tokenTypeIDsName: String?,
            positionIDsName: String?
        ) -> Bool {
            let declaredInputs = Set(model.modelDescription.inputDescriptionsByName.keys)
            guard declaredInputs.contains(inputIDsName) else { return false }
            let length = 4
            guard
                let ids = try? MLInt32Input.make(length: length, { _ in 1 }),
                let mask = try? MLInt32Input.make(length: length, { _ in 1 })
            else { return false }

            var features: [String: MLFeatureValue] = [
                inputIDsName: MLFeatureValue(multiArray: ids)
            ]
            if declaredInputs.contains(attentionMaskName) {
                features[attentionMaskName] = MLFeatureValue(multiArray: mask)
            }
            for optional in [tokenTypeIDsName, positionIDsName] {
                guard let name = optional, declaredInputs.contains(name),
                    let zeros = try? MLInt32Input.make(length: length, { _ in 0 })
                else { continue }
                features[name] = MLFeatureValue(multiArray: zeros)
            }
            guard let provider = try? MLDictionaryFeatureProvider(dictionary: features) else {
                return false
            }
            return (try? model.prediction(from: provider)) != nil
        }
    }

    private enum MLInt32Input {
        /// A `[1, length]` Int32 `MLMultiArray`, each element supplied by `value`.
        static func make(length: Int, _ value: (Int) -> Int32) throws -> MLMultiArray {
            let array: MLMultiArray
            do {
                array = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(reason: "\(error)")
            }
            for index in 0..<length {
                array[[0, NSNumber(value: index)]] = NSNumber(value: value(index))
            }
            return array
        }
    }

    /// Provider-local error reasons, wrapped by
    /// ``SemanticEmbeddingError/modelLoadFailed(underlying:)``.
    private enum HFProviderError: Error, LocalizedError, CustomStringConvertible {
        case noModel(String)
        case noWorkingComputeUnit(String)

        var description: String {
            switch self {
            case .noModel(let path): "No .mlpackage or .mlmodelc found in \(path)"
            case .noWorkingComputeUnit(let name):
                """
                \(name) failed a trial prediction on every compute unit (ANE, GPU, CPU) — \
                the export is likely incompatible with this Core ML runtime
                """
            }
        }

        /// `modelLoadFailed` renders its underlying error through
        /// `localizedDescription`, which for a plain Swift error is opaque NSError
        /// bridging noise ("The operation couldn't be completed…"). A bad
        /// `--embedding-bundle` is the most likely error a user will ever see from
        /// this provider, so route it back to the sentence that names the problem.
        var errorDescription: String? { description }
    }
#endif
