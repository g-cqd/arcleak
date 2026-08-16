import ArcLeakCore
import SystemPackage

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Minimal LSP sidecar, hand-rolled stdio JSON-RPC (no unstable third-party
/// LSP dependencies — SourceKit-LSP's library products are underscored, per
/// the research on record). Hard-capped scope:
///
/// - `initialize` / `shutdown` / `exit`
/// - `textDocument/didOpen|didChange|didSave|didClose` → `publishDiagnostics`
/// - `textDocument/codeAction` → suppress-with-`@al:accept` quick fix
///
/// Analysis reuses `Analyzer` per document (single-file corpus); documents are
/// kept in memory with full-sync semantics.
///
/// Typed `Codable` messages over `SystemPackage.FileDescriptor`, not
/// `JSONSerialization` + `FileHandle`: those live in corelibs Foundation, and
/// this file was the last thing keeping arcleak's Linux binary linked against
/// ~47 MiB of ICU. The message surface is small and closed, so typing it is
/// also just better LSP hygiene — a malformed field now fails decode instead of
/// silently reading as `nil`.
///
/// Known limit: `didChange` re-analyzes synchronously with no debounce — fine
/// for a hard-capped single-file analyzer, but a busy-typing large file
/// re-parses per keystroke. Debounce needs an async server loop redesign;
/// tracked as future work, deliberately out of scope here.
struct LspServer {
    private let analyzer = Analyzer()
    private var openDocuments: [String: String] = [:]
    private var lastFindings: [String: [Finding]] = [:]

    // MARK: - Wire types

    /// JSON-RPC ids are a number or a string; both must round-trip verbatim.
    enum MessageID: Codable, Sendable {
        case number(Int)
        case string(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let number): try container.encode(number)
            case .string(let string): try container.encode(string)
            }
        }
    }

    /// The union of every incoming message this server reacts to. Fields the
    /// method does not use simply decode to nil.
    struct Incoming: Decodable {
        struct TextDocument: Decodable {
            let uri: String
            let text: String?
        }
        struct ContentChange: Decodable {
            let text: String
        }
        struct Position: Decodable {
            let line: Int
            let character: Int
        }
        struct Range: Decodable {
            let start: Position
            let end: Position
        }
        struct Params: Decodable {
            let textDocument: TextDocument?
            let contentChanges: [ContentChange]?
            let range: Range?
        }

        let id: MessageID?
        let method: String?
        let params: Params?
    }

    struct OutPosition: Encodable {
        let line: Int
        let character: Int
    }
    struct OutRange: Encodable {
        let start: OutPosition
        let end: OutPosition
    }
    struct Diagnostic: Encodable {
        let range: OutRange
        let severity: Int
        let code: String
        let source: String
        let message: String
    }
    struct PublishDiagnostics: Encodable {
        struct Params: Encodable {
            let uri: String
            let diagnostics: [Diagnostic]
        }
        let jsonrpc = "2.0"
        let method = "textDocument/publishDiagnostics"
        let params: Params
    }
    struct InitializeResult: Encodable {
        struct Capabilities: Encodable {
            let textDocumentSync = 1  // full
            let codeActionProvider = true
        }
        struct ServerInfo: Encodable {
            let name: String
            let version: String
        }
        let capabilities = Capabilities()
        let serverInfo = ServerInfo(name: ToolInfo.name, version: ToolInfo.version)
    }
    struct CodeAction: Encodable {
        struct TextEdit: Encodable {
            let range: OutRange
            let newText: String
        }
        struct WorkspaceEdit: Encodable {
            let changes: [String: [TextEdit]]
        }
        let title: String
        let kind = "quickfix"
        let diagnostics: [Diagnostic] = []
        let edit: WorkspaceEdit
    }
    /// `"result": null` — LSP requires the key to be present.
    struct NullResult: Encodable {
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    struct Response<Result: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: MessageID
        let result: Result
    }

    // MARK: - Loop

    static func run() throws {
        var server = LspServer()
        while true {
            guard let message = Self.readMessage() else { return }
            if server.handle(message) == false {
                return
            }
        }
    }

    // MARK: - Framing

    /// Bounds against a malicious/confused client: a header with no terminator
    /// or an absurd `Content-Length` must drop the connection, not buffer to
    /// OOM. Returning nil ends the read loop cleanly.
    private static let maxHeaderBytes = 4 * 1024
    private static let maxBodyBytes = 16 * 1024 * 1024

    /// One byte from stdin, or nil at EOF/error.
    ///
    /// `unsafe`: `FileDescriptor.read` is a raw-buffer API. The invariant is
    /// total — the buffer is a single stack byte valid for exactly this call.
    private static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let count = withUnsafeMutableBytes(of: &byte) { buffer in
            (try? unsafe FileDescriptor.standardInput.read(into: buffer)) ?? 0
        }
        return count == 1 ? byte : nil
    }

    /// Exactly `count` bytes from stdin, or nil on early EOF.
    ///
    /// `unsafe`: same raw-buffer contract as `readByte`; the slice rebased per
    /// iteration never escapes the closure.
    private static func readExactly(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let read = bytes.withUnsafeMutableBytes { buffer in
                (try? unsafe FileDescriptor.standardInput.read(
                    into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled...]))) ?? 0
            }
            if read <= 0 { return nil }
            filled += read
        }
        return bytes
    }

    private static func readMessage() -> Incoming? {
        var header: [UInt8] = []
        while !(header.count >= 4 && header.suffix(4) == [13, 10, 13, 10]) {
            guard let byte = readByte() else { return nil }
            header.append(byte)
            if header.count > maxHeaderBytes { return nil }
        }
        let text = String(decoding: header, as: UTF8.self)
        guard
            let lengthLine = text.split(separator: "\r\n").first(where: {
                $0.lowercased().hasPrefix("content-length:")
            }),
            let lengthField = lengthLine.split(separator: ":").last,
            // Digits only — the field arrives as " 123" (and may carry a
            // stray \r); trimmingCharacters is corelibs-only.
            let length = Int(lengthField.filter(\.isNumber)),
            length >= 0, length <= maxBodyBytes
        else { return nil }

        guard let body = readExactly(length) else { return nil }
        return try? JSONDecoder().decode(Incoming.self, from: Data(body))
    }

    private static func send(_ payload: some Encodable) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        var out = [UInt8]("Content-Length: \(data.count)\r\n\r\n".utf8)
        out.append(contentsOf: data)
        _ = try? FileDescriptor.standardOutput.writeAll(out)
    }

    // MARK: - Dispatch

    private mutating func handle(_ message: Incoming) -> Bool {
        let params = message.params

        switch message.method {
        case "initialize":
            respond(id: message.id, result: InitializeResult())
        case "shutdown":
            respond(id: message.id, result: NullResult())
        case "exit":
            return false
        case "textDocument/didOpen":
            if let document = params?.textDocument, let text = document.text {
                openDocuments[document.uri] = text
                publishDiagnostics(uri: document.uri, source: text)
            }
        case "textDocument/didChange":
            if let uri = params?.textDocument?.uri,
                let text = params?.contentChanges?.last?.text
            {
                openDocuments[uri] = text
                publishDiagnostics(uri: uri, source: text)
            }
        case "textDocument/didSave":
            if let uri = params?.textDocument?.uri, let source = openDocuments[uri] {
                publishDiagnostics(uri: uri, source: source)
            }
        case "textDocument/didClose":
            // Without this the two maps grow for the whole session — a leak in
            // the leak tool. Drop the document and clear its diagnostics.
            if let uri = params?.textDocument?.uri {
                openDocuments.removeValue(forKey: uri)
                lastFindings.removeValue(forKey: uri)
                Self.send(
                    PublishDiagnostics(params: .init(uri: uri, diagnostics: [])))
            }
        case "textDocument/codeAction":
            respond(id: message.id, result: codeActions(params: params))
        default:
            // Unknown *request* (has id) gets an empty result so clients don't hang.
            if message.id != nil {
                respond(id: message.id, result: NullResult())
            }
        }
        return true
    }

    private func respond(id: MessageID?, result: some Encodable) {
        guard let id else { return }
        Self.send(Response(id: id, result: result))
    }

    // MARK: - Diagnostics

    private mutating func publishDiagnostics(uri: String, source: String) {
        let path = uri.hasPrefix("file://") ? String(uri.dropFirst(7)) : uri
        let findings = analyzer.analyze(source: source, path: path).findings
        lastFindings[uri] = findings

        let diagnostics = findings.map { finding in
            Diagnostic(
                range: Self.range(line: finding.line, column: finding.column),
                severity: finding.severity == .error ? 1 : 2,
                code: finding.rule.rawValue,
                source: ToolInfo.name,
                message: finding.note.map { "\(finding.message) — \($0)" } ?? finding.message
            )
        }
        Self.send(PublishDiagnostics(params: .init(uri: uri, diagnostics: diagnostics)))
    }

    private func codeActions(params: Incoming.Params?) -> [CodeAction] {
        guard
            let uri = params?.textDocument?.uri,
            let line = params?.range?.start.line
        else { return [] }

        return (lastFindings[uri] ?? [])
            .filter { $0.line - 1 == line }
            .map { finding in
                let insertion = CodeAction.TextEdit(
                    range: Self.range(line: finding.line, column: 1),
                    newText: "// @al:accept -- reviewed: \(finding.rule.rawValue)\n"
                )
                return CodeAction(
                    title: "Suppress with @al:accept",
                    edit: .init(changes: [uri: [insertion]])
                )
            }
    }

    /// LSP positions are 0-based; findings are 1-based.
    private static func range(line: Int, column: Int) -> OutRange {
        let position = OutPosition(line: max(0, line - 1), character: max(0, column - 1))
        return OutRange(start: position, end: position)
    }
}
