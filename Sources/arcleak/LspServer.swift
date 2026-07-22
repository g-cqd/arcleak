import ArcLeakCore
import Foundation

/// Minimal LSP sidecar, hand-rolled stdio JSON-RPC (no unstable third-party
/// LSP dependencies — SourceKit-LSP's library products are underscored, per
/// the research on record). Hard-capped scope:
///
/// - `initialize` / `shutdown` / `exit`
/// - `textDocument/didOpen|didChange|didSave` → `publishDiagnostics`
/// - `textDocument/codeAction` → suppress-with-`deliberate` quick fix
///
/// Analysis reuses `Analyzer` per document (single-file corpus); documents are
/// kept in memory with full-sync semantics.
struct LspServer {
    private let analyzer = Analyzer()
    private var openDocuments: [String: String] = [:]
    private var lastFindings: [String: [Finding]] = [:]

    static func run() throws {
        var server = LspServer()
        let input = FileHandle.standardInput
        while true {
            guard let message = Self.readMessage(from: input) else { return }
            if try server.handle(message) == false {
                return
            }
        }
    }

    // MARK: - Framing

    private static func readMessage(from handle: FileHandle) -> [String: Any]? {
        var header = Data()
        // Read byte-wise until the blank line — header sizes are tiny.
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard let byte = try? handle.read(upToCount: 1), !byte.isEmpty else { return nil }
            header.append(byte)
        }
        guard
            let text = String(data: header, encoding: .utf8),
            let lengthLine = text.split(separator: "\r\n").first(where: {
                $0.lowercased().hasPrefix("content-length:")
            }),
            let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
        else { return nil }

        var body = Data()
        while body.count < length {
            guard let chunk = try? handle.read(upToCount: length - body.count), !chunk.isEmpty
            else { return nil }
            body.append(chunk)
        }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var out = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
        out.append(data)
        FileHandle.standardOutput.write(out)
    }

    // MARK: - Dispatch

    /// Returns false when the client asked to exit.
    private mutating func handle(_ message: [String: Any]) throws -> Bool {
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            respond(
                id: id,
                result: [
                    "capabilities": [
                        "textDocumentSync": 1,  // full
                        "codeActionProvider": true,
                    ] as [String: Any],
                    "serverInfo": ["name": ToolInfo.name, "version": ToolInfo.version],
                ]
            )
        case "shutdown":
            respond(id: id, result: NSNull())
        case "exit":
            return false
        case "textDocument/didOpen":
            if let document = params["textDocument"] as? [String: Any],
                let uri = document["uri"] as? String,
                let text = document["text"] as? String
            {
                openDocuments[uri] = text
                publishDiagnostics(uri: uri, source: text)
            }
        case "textDocument/didChange":
            if let document = params["textDocument"] as? [String: Any],
                let uri = document["uri"] as? String,
                let changes = params["contentChanges"] as? [[String: Any]],
                let text = changes.last?["text"] as? String
            {
                openDocuments[uri] = text
                publishDiagnostics(uri: uri, source: text)
            }
        case "textDocument/didSave":
            if let document = params["textDocument"] as? [String: Any],
                let uri = document["uri"] as? String,
                let source = openDocuments[uri]
            {
                publishDiagnostics(uri: uri, source: source)
            }
        case "textDocument/codeAction":
            respond(id: id, result: codeActions(params: params))
        default:
            // Unknown *request* (has id) gets an empty result so clients don't hang.
            if id != nil {
                respond(id: id, result: NSNull())
            }
        }
        return true
    }

    private func respond(id: Any?, result: Any) {
        guard let id else { return }
        Self.send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    // MARK: - Diagnostics

    private mutating func publishDiagnostics(uri: String, source: String) {
        let path = uri.hasPrefix("file://") ? String(uri.dropFirst(7)) : uri
        let findings = analyzer.analyze(source: source, path: path).findings
        lastFindings[uri] = findings

        let diagnostics: [[String: Any]] = findings.map { finding in
            [
                "range": Self.range(line: finding.line, column: finding.column),
                "severity": finding.severity == .error ? 1 : 2,
                "code": finding.rule.rawValue,
                "source": ToolInfo.name,
                "message": finding.note.map { "\(finding.message) — \($0)" } ?? finding.message,
            ]
        }
        Self.send([
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": ["uri": uri, "diagnostics": diagnostics] as [String: Any],
        ])
    }

    private func codeActions(params: [String: Any]) -> [[String: Any]] {
        guard
            let document = params["textDocument"] as? [String: Any],
            let uri = document["uri"] as? String,
            let range = params["range"] as? [String: Any],
            let start = range["start"] as? [String: Any],
            let line = start["line"] as? Int
        else { return [] }

        return (lastFindings[uri] ?? [])
            .filter { $0.line - 1 == line }
            .map { finding in
                let insertion = [
                    "range": Self.range(line: finding.line, column: 1),
                    "newText": "// arcleak:deliberate -- reviewed: \(finding.rule.rawValue)\n",
                ]
                return [
                    "title": "Suppress with arcleak:deliberate",
                    "kind": "quickfix",
                    "diagnostics": [],
                    "edit": ["changes": [uri: [insertion]]] as [String: Any],
                ]
            }
    }

    /// LSP positions are 0-based; findings are 1-based.
    private static func range(line: Int, column: Int) -> [String: Any] {
        let position: [String: Any] = ["line": max(0, line - 1), "character": max(0, column - 1)]
        return ["start": position, "end": position]
    }
}
