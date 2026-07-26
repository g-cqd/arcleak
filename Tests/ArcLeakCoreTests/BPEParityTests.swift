//  BPEParityTests.swift
//  arcleak
//
//  Pins the hand-rolled ``BPETokenizer`` against HuggingFace's
//  `swift-transformers`, token id for token id, using the real CodeBERT
//  vocabulary (50,265 tokens / 50,000 merges).
//
//  Same contract as `WordPieceParityTests`: a tokenizer that disagrees with the
//  one the model was trained with yields silently wrong vectors — no error, just
//  meaningless output — so parity is asserted over a corpus rather than a few
//  hand-picked strings. The differential half is `#if canImport(Tokenizers)`, so
//  it compiles away with the dependency and leaves the rest as the permanent pin.

import Foundation
import Testing

@testable import ArcLeakCore

#if canImport(Tokenizers)
    import Tokenizers
#endif

@Suite struct BPEParityTests {
    static let bundle = "/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Models/CodeBERT"
    static var bundleAvailable: Bool { FileManager.default.fileExists(atPath: bundle) }

    /// Byte-level BPE has failure modes WordPiece does not: the leading-space
    /// (`Ġ`) convention, byte fallback for anything non-ASCII, CJK and emoji as
    /// multi-byte sequences, contractions (which the regex splits explicitly),
    /// and long merge chains in camelCase.
    static let probes: [String] = [
        "func handleTap() { self.delegate?.didTap(self) }",
        "let x: [String: any Sendable] = [:]",
        "guard let self else { return }   // early-exit",
        "cancellable = publisher.sink { [weak self] value in self?.apply(value) }",
        "aVeryLongCamelCaseIdentifierThatBPEMustSplitIntoManySubwords",
        "/// Résumé naïve café — accented comment with em-dash",
        "let emoji = \"🎉 done\" // trailing",
        "if a<=b && c>=d || e!=f { x += 1 }",
        "@MainActor final class ViewModel: ObservableObject {}",
        "  leading and   internal   runs of spaces",
        "\ttab\tseparated\tvalues",
        "",
        " ",
        "日本語のコメント",
        "snake_case_and_UPPER_CASE_MIXED",
        "0x1F_ffff + 1_000_000 * 3.14e-2",
        "don't can't we've I'll they're it's",
    ]

    static func corpusSnippets(limit: Int) -> [String] {
        let root = "/Users/gc/Developer/ongoing/swift/arcleak/Sources"
        var paths: [String] = []
        if let e = FileManager.default.enumerator(atPath: root) {
            for case let p as String in e where p.hasSuffix(".swift") {
                paths.append(root + "/" + p)
            }
        }
        var out: [String] = []
        for path in paths.sorted() {
            guard let src = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            else { continue }
            let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(line)
                if out.count >= limit { return out }
            }
            for start in stride(from: 0, to: lines.count, by: 12) {
                let window = lines[start..<min(start + 12, lines.count)].joined(separator: "\n")
                if !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(window)
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    @Test(
        "RoBERTa special tokens wrap every sequence",
        .enabled(if: BPEParityTests.bundleAvailable))
    func specialTokens() throws {
        let tokenizer = try BPETokenizer(bundleDir: URL(fileURLWithPath: Self.bundle))
        let ids = tokenizer.encode(text: "let value = compute()")
        // RobertaProcessing declares <s> = 0 … </s> = 2.
        #expect(ids.first == 0, "<s> must open every sequence")
        #expect(ids.last == 2, "</s> must close every sequence")
        #expect(ids.count > 2, "content tokens expected between the specials")
        // Byte-level BPE is total over bytes, so nothing can fall back to <unk>.
        #expect(!ids.contains(3), "byte-level BPE should never emit <unk>")
    }

    @Test(
        "The dispatcher picks BPE for CodeBERT and WordPiece for MiniLM",
        .enabled(if: BPEParityTests.bundleAvailable))
    func dispatcherSelectsByDeclaredType() throws {
        let bpe = try BundleTokenizer.make(bundleDir: URL(fileURLWithPath: Self.bundle))
        #expect(bpe is BPETokenizer, "CodeBERT declares model.type == BPE")
        let miniLM = "/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Models/MiniLM"
        if FileManager.default.fileExists(atPath: miniLM) {
            let wordPiece = try BundleTokenizer.make(bundleDir: URL(fileURLWithPath: miniLM))
            #expect(wordPiece is WordPieceTokenizer, "MiniLM declares model.type == WordPiece")
        }
    }

    @Test(
        "A leading space is significant (the Ġ convention)",
        .enabled(if: BPEParityTests.bundleAvailable))
    func leadingSpaceIsSignificant() throws {
        let tokenizer = try BPETokenizer(bundleDir: URL(fileURLWithPath: Self.bundle))
        // The defining property of byte-level BPE, and the one a naive
        // implementation loses: " self" and "self" are different tokens.
        #expect(
            tokenizer.encode(text: "self") != tokenizer.encode(text: " self"),
            "a leading space must change the tokenization")
    }

    #if canImport(Tokenizers)
        @Test(
            "DIFFERENTIAL: matches swift-transformers token-for-token on the arcleak corpus",
            .enabled(if: BPEParityTests.bundleAvailable))
        func matchesSwiftTransformers() async throws {
            let mine = try BPETokenizer(bundleDir: URL(fileURLWithPath: Self.bundle))
            let reference = try await AutoTokenizer.from(
                modelFolder: URL(fileURLWithPath: Self.bundle))

            var checked = 0
            var mismatches: [(String, [Int], [Int])] = []
            for snippet in Self.probes + Self.corpusSnippets(limit: 12000) {
                let a = mine.encode(text: snippet)
                let b = reference.encode(text: snippet)
                checked += 1
                if a != b, mismatches.count < 5 { mismatches.append((snippet, a, b)) }
            }
            for (snippet, a, b) in mismatches {
                print(
                    """
                    MISMATCH on: \(snippet.prefix(90).debugDescription)
                      mine: \(a.prefix(24))
                      ref : \(b.prefix(24))
                    """)
            }
            #expect(mismatches.isEmpty, "\(mismatches.count) mismatching snippet(s) of \(checked)")
            print("BPE parity: \(checked) snippets identical to swift-transformers")
        }
    #endif
}
