import ArcLeakCore
import Foundation
import Testing

/// A user-declared `sinkWrapper` contract teaches arcleak to see through a
/// custom Combine wrapper (`React.to`, reduced from the Stations corpus): the
/// wrapper's closure is analyzed for strong-`self` capture exactly like `.sink`,
/// and a returned token stored on `self` closes a `combine-sink-self-cycle`.
/// Without the contract arcleak stays silent — it never invents a cross-wrapper
/// cycle it cannot prove.
@Suite struct SinkWrapperContractTests {
    /// Faithful reduction of Stations' `SpotifyPlatform.addReactions()`:
    /// `React.to(.name) { self.… }` stored on a `React.Task?` (an
    /// `AnyCancellable` typealias) property, alongside a correct `[weak self]`
    /// reaction and a discarded token.
    private let source = """
        import Combine

        struct ReactName { let raw: String }

        enum React {
            typealias Task = AnyCancellable
            static func to(
                _ name: ReactName,
                with action: @escaping (Int) -> Void
            ) -> React.Task {
                fatalError("wrapper body is opaque to arcleak")
            }
        }

        final class Platform {
            private var becomeInactiveTask: React.Task?
            private var becomeActiveTask: React.Task?

            func addReactions() {
                becomeInactiveTask = React.to(ReactName(raw: "resign")) { _ in
                    self.disconnect()
                }
                becomeActiveTask = React.to(ReactName(raw: "active")) { [weak self] _ in
                    self?.connect()
                }
            }

            func dropReaction() {
                _ = React.to(ReactName(raw: "x")) { _ in print("no owner") }
            }

            func disconnect() {}
            func connect() {}
        }
        """

    /// The exact `.arcleak.json` a user writes to declare the wrapper, loaded
    /// through the real fail-closed config path.
    private func contractConfiguration() throws -> Configuration {
        let json = """
            {
              "rules": {},
              "exclude": [],
              "contracts": [
                {
                  "callee": "to",
                  "base": "React",
                  "template": "sinkWrapper",
                  "tokenName": "the React.to subscription"
                }
              ]
            }
            """
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-sinkwrapper-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Configuration.load(path: url.path)
    }

    @Test("Without the contract, the custom React.to wrapper is invisible")
    func silentWithoutContract() {
        #expect(Analyzer().analyze(source: source, path: "Platform.swift").findings.isEmpty)
    }

    @Test("With the contract, the strong-self wrapper cycle fires; the weak one does not")
    func contractFlagsStrongSelfCycle() throws {
        let findings = try Analyzer(configuration: contractConfiguration())
            .analyze(source: source, path: "Platform.swift").findings

        // Exactly the strong-self stored cycle and the discarded token — the
        // `[weak self]` reaction stays silent (no false positive).
        #expect(
            findings.map(\.rule).sorted { $0.rawValue < $1.rawValue }
                == [.combineSinkSelfCycle, .unstoredLifetimeToken]
        )

        let cycle = try #require(findings.first { $0.rule == .combineSinkSelfCycle })
        #expect(cycle.message.contains("the React.to subscription"))
        #expect(cycle.message.contains("captures self strongly"))

        let dropped = try #require(findings.first { $0.rule == .unstoredLifetimeToken })
        #expect(dropped.message.contains("the React.to subscription"))
    }

    @Test("A tokenProducer contract still does NOT feed the sink-cycle rule")
    func tokenProducerDoesNotFlagCycle() throws {
        // Same wrapper, declared only as a plain token producer: the stored
        // strong-self call is a cycle in reality, but arcleak stays
        // conservative — only `sinkWrapper` opts the closure into cycle checks.
        let configuration = Configuration(contracts: [
            .init(callee: "to", base: "React", tokenName: "the React.to subscription", template: .tokenProducer)
        ])
        let findings = Analyzer(configuration: configuration)
            .analyze(source: source, path: "Platform.swift").findings
        #expect(!findings.contains { $0.rule == .combineSinkSelfCycle })
        // The discarded token is still caught by the premature-release family.
        #expect(findings.map(\.rule) == [.unstoredLifetimeToken])
    }
}
