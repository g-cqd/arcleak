import AemiJSON
import AemiProtobuf
import Foundation
import Testing

@testable import ArcLeakCore

/// arcleak's facts cache payloads are protobuf (analyzerkit roadmap 0017): every facts type round-trips, enums with
/// associated values included, and a 3,000-file corpus stays within its size budget.
@Suite struct ProtobufPayloadTests {
    /// A file with stored closures, timers, Combine sinks, tasks, delegates, release sites and directives.
    static func source(_ index: Int) -> String {
        """
        import Combine
        import Foundation

        // @arcleak:accept:next timer-retains-self -- invalidated in stop \\(index)
        final class Poller\(index): NSObject {
            weak var delegate: AnyObject?
            unowned let owner: NSObject
            var handler: (() -> Void)?
            var bag = Set<AnyCancellable>()
            private var timer: Timer?
            @Published var count = \(index)

            init(owner: NSObject) { self.owner = owner }

            func start(subject: PassthroughSubject<Int, Never>) {
                handler = { self.tick() }
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                subject.sink { value in self.count = value }.store(in: &bag)
                Task { while true { await self.poll() } }
            }

            func tick() {}
            func poll() async {}
            deinit { timer?.invalidate() }
        }

        struct Value\(index) { let id = \(index) }
        """
    }

    static func extracted(_ index: Int) -> ExtractedFacts {
        Analyzer.extract(
            bytes: Array(source(index).utf8), path: "/corpus/Sources/Module\(index % 40)/File\(index).swift",
            configuration: .default, platforms: [])
    }

    /// The facts as text, sets sorted, so two equal facts read the same whatever order their sets iterate in.
    static func canonical(_ facts: FileFacts) -> String {
        var lines = [
            facts.path,
            "\(facts.directives.map { "\($0.rules.map(\.rawValue).sorted()) \($0.kind) \($0.line) \($0.reason ?? "-")" })",
            "\(facts.regionSpans)", "\(facts.isTestCode) \(facts.isGenerated)",
        ]
        for type in facts.types {
            lines += [
                type.name, "\(String(describing: type.isReferenceType))", "\(type.memberNames.sorted())",
                "\(type.inheritedTypeNames.sorted())", "\(type.methodNames.sorted())",
                "\(type.attributeNames.sorted())",
                "\(type.deadWeakCaptures)", "\(type.storedProperties)", "\(type.storedClosures)", "\(type.apiCalls)",
                "\(type.taskSpawns)", "\(type.releaseSites)",
            ]
        }
        return lines.joined(separator: "\n")
    }

    @Test(arguments: [true, false])
    func `every facts type round-trips through protobuf`(rich: Bool) throws {
        let original = rich ? ExtractedFacts(facts: CacheTests.richFacts(path: "/x/Sample.swift")) : Self.extracted(3)
        let facts = try #require(original.facts)
        #expect(!facts.types.isEmpty)
        let bytes = try ProtobufEncoder().encodeToBytes(original)
        let decoded = try #require(try ProtobufDecoder().decode(ExtractedFacts.self, fromBytes: bytes).facts)
        #expect(Self.canonical(decoded) == Self.canonical(facts))
        #expect(try ProtobufEncoder().encodeToBytes(ExtractedFacts(facts: decoded)) == bytes, "byte-stable")

        let degraded = try ProtobufDecoder().decode(
            ExtractedFacts.self, fromBytes: ProtobufEncoder().encodeToBytes(ExtractedFacts(degraded: "not valid UTF-8"))
        )
        #expect(degraded.degraded == "not valid UTF-8" && degraded.facts == nil)
    }

    /// The budget is set from 0017's measurement (JSON 8.5 MB, protobuf 2.0 MB for these 3,000 files): protobuf must stay
    /// under a third of what the JSON path wrote.
    @Test func `a 3,000-file corpus stays within its size budget`() throws {
        var json = 0
        var protobuf = 0
        for index in 0..<3_000 {
            let file = Self.extracted(index)
            json += try AemiJSON.JSONEncoder().encodeToBytes(file).count
            protobuf += try ProtobufEncoder().encodeToBytes(file).count
        }
        print("ProtobufPayloadTests: 3,000 files, JSON \(json) bytes, protobuf \(protobuf) bytes")
        #expect(protobuf * 3 < json, "JSON \(json) bytes, protobuf \(protobuf)")
    }
}
