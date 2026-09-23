import Foundation
import Testing

@Suite struct LspProtocolTests {
    @Test("LSP diagnostics and code actions use UTF-16 positions across CRLF and a byte-order mark")
    func positionsUseUTF16() throws {
        let line = #"    func arm() { let _ = "é한𝄞😀"; handler = { self.fire() } }"#
        let source =
            "\u{FEFF}final class Box {\r\n    var handler: (() -> Void)?\r\n\(line)\r\n    func fire() {}\r\n}\r\n"
        let root = try Workspace.make(["Box.swift": source])
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = root.appending(path: "Box.swift").absoluteString
        let position = WirePosition(line: 2, character: try Workspace.utf16Column(of: "{ self", in: line) - 1)
        let messages = [
            Request(id: 1, method: "initialize"),
            Request(method: "textDocument/didOpen", params: .init(textDocument: .init(uri: uri, text: source))),
            Request(
                id: 2, method: "textDocument/codeAction",
                params: .init(textDocument: .init(uri: uri), range: .init(point: position))),
            Request(
                id: 3, method: "textDocument/codeAction",
                params: .init(textDocument: .init(uri: uri), range: .init(point: .init(line: 2, character: 0)))),
            Request(id: 4, method: "shutdown"),
            Request(method: "exit"),
        ]
        let replies = try run(messages, in: root)
        let diagnostics = try #require(publications(in: replies).first?.params.diagnostics)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.range == WireRange(point: position))

        let matching = try actions(id: 2, in: replies)
        #expect(matching.count == 1)
        let insertion = try #require(matching.first?.edit.changes[uri]?.first)
        #expect(insertion.range == WireRange(point: .init(line: 2, character: 0)))
        #expect(try actions(id: 3, in: replies).isEmpty)
    }

    @Test("A byte-order mark counts as one UTF-16 unit on the first line after didChange")
    func firstLineByteOrderMark() throws {
        let line =
            #"final class Box { var handler: (() -> Void)?; func arm() { let _ = "é한𝄞😀"; handler = { self.fire() } }; func fire() {} }"#
        let root = try Workspace.make(["Box.swift": line])
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = root.appending(path: "Box.swift").absoluteString
        let source = "\u{FEFF}" + line + "\r\n"
        let position = WirePosition(line: 0, character: try Workspace.utf16Column(of: "{ self", in: source) - 1)
        let messages = [
            Request(
                method: "textDocument/didOpen",
                params: .init(textDocument: .init(uri: uri, text: "final class Box {}\n"))),
            Request(
                method: "textDocument/didChange",
                params: .init(textDocument: .init(uri: uri), contentChanges: [.init(text: source)])),
            Request(
                id: 2, method: "textDocument/codeAction",
                params: .init(textDocument: .init(uri: uri), range: .init(point: position))),
            Request(method: "exit"),
        ]
        let replies = try run(messages, in: root)
        let published = try publications(in: replies)
        #expect(published.count == 2)
        let diagnostic = try #require(published.last?.params.diagnostics.first)
        #expect(diagnostic.range == WireRange(point: position))
        let insertion = try #require(actions(id: 2, in: replies).first?.edit.changes[uri]?.first)
        #expect(insertion.range == WireRange(point: .init(line: 0, character: 1)))
    }

    private struct WirePosition: Codable, Equatable {
        let line: Int
        let character: Int
    }

    private struct WireRange: Codable, Equatable {
        let start: WirePosition
        let end: WirePosition

        init(point: WirePosition) {
            start = point
            end = point
        }
    }

    private struct Request: Encodable {
        struct TextDocument: Encodable {
            let uri: String
            let text: String?

            init(uri: String, text: String? = nil) {
                self.uri = uri
                self.text = text
            }
        }

        struct ContentChange: Encodable {
            let text: String
        }

        struct Params: Encodable {
            let textDocument: TextDocument?
            let contentChanges: [ContentChange]?
            let range: WireRange?

            init(textDocument: TextDocument? = nil, contentChanges: [ContentChange]? = nil, range: WireRange? = nil) {
                self.textDocument = textDocument
                self.contentChanges = contentChanges
                self.range = range
            }
        }

        let jsonrpc = "2.0"
        let id: Int?
        let method: String
        let params: Params?

        init(id: Int? = nil, method: String, params: Params? = nil) {
            self.id = id
            self.method = method
            self.params = params
        }
    }

    private struct Envelope: Decodable {
        let id: Int?
        let method: String?
    }

    private struct Publication: Decodable {
        struct Params: Decodable {
            struct Diagnostic: Decodable {
                let range: WireRange
            }
            let diagnostics: [Diagnostic]
        }
        let params: Params
    }

    private struct ActionResponse: Decodable {
        struct Action: Decodable {
            struct Edit: Decodable {
                struct TextEdit: Decodable {
                    let range: WireRange
                }
                let changes: [String: [TextEdit]]
            }
            let edit: Edit
        }
        let result: [Action]
    }

    private func publications(in replies: [Data]) throws -> [Publication] {
        let decoder = JSONDecoder()
        return try replies.compactMap { data in
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.method == "textDocument/publishDiagnostics" else { return nil }
            return try decoder.decode(Publication.self, from: data)
        }
    }

    private func actions(id: Int, in replies: [Data]) throws -> [ActionResponse.Action] {
        let decoder = JSONDecoder()
        let response = try #require(replies.first { (try? decoder.decode(Envelope.self, from: $0))?.id == id })
        return try decoder.decode(ActionResponse.self, from: response).result
    }

    private func run(_ messages: [Request], in directory: URL) throws -> [Data] {
        let executable = try #require(BuiltTool.executable)
        let input = directory.appending(path: "input")
        let output = directory.appending(path: "output")
        var framed = Data()
        let encoder = JSONEncoder()
        for message in messages {
            let body = try encoder.encode(message)
            framed.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
            framed.append(body)
        }
        try framed.write(to: input)
        try Data().write(to: output)
        let inputHandle = try FileHandle(forReadingFrom: input)
        defer { try? inputHandle.close() }
        let outputHandle = try FileHandle(forWritingTo: output)
        defer { try? outputHandle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["lsp"]
        process.currentDirectoryURL = directory
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        let bytes = [UInt8](try Data(contentsOf: output))
        var offset = 0
        var replies: [Data] = []
        while offset < bytes.count {
            let separator = try #require(bytes[offset...].firstRange(of: [13, 10, 13, 10]))
            let header = String(decoding: bytes[offset..<separator.lowerBound], as: UTF8.self)
            let lengthText = try #require(header.split(separator: ":").last)
            let length = try #require(Int(lengthText.trimmingCharacters(in: .whitespaces)))
            let end = separator.upperBound + length
            try #require(end <= bytes.count)
            replies.append(Data(bytes[separator.upperBound..<end]))
            offset = end
        }
        return replies
    }
}
