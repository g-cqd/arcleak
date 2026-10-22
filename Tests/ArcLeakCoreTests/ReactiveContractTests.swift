import ArcLeakCore
import Foundation
import Testing

/// The `disposeBag` and `signalDisposable` contract templates: built in for
/// RxSwift's `subscribe`/`bind`/`drive` and SwiftSignalKit's `start(next:)`,
/// and declarable through `contracts` for other spellings, like `sinkWrapper`.
@Suite struct ReactiveContractTests {
    /// RxSwift 2 spellings: `subscribeNext` and `addDisposableTo(_:)`.
    private let legacySource = """
        import RxSwift

        final class LegacyViewModel {
            let disposeBag = DisposeBag()
            let refresh = PublishSubject<Void>()
            var count = 0

            func bindInputs() {
                refresh.subscribeNext { _ in
                    self.count += 1
                }.addDisposableTo(disposeBag)
            }
        }
        """

    /// A home-grown signal type whose subscription method is `observe(each:)`.
    private let customSignalSource = """
        final class Watcher {
            let disposable = SerialDisposable()
            let values = ValueSignal<Int>()
            var last = 0

            func watch() {
                disposable.set(values.observe(each: { value in self.last = value }))
            }
        }
        """

    private func load(_ json: String) throws -> Configuration {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-reactive-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Configuration.load(path: url.path)
    }

    @Test("Without a contract, other reactive spellings stay silent")
    func silentWithoutContract() {
        #expect(Analyzer().analyze(source: legacySource, path: "Legacy.swift").findings.isEmpty)
        #expect(Analyzer().analyze(source: customSignalSource, path: "Watcher.swift").findings.isEmpty)
    }

    @Test("A disposeBag contract flags a strong-self subscription kept in a bag on self")
    func disposeBagContract() throws {
        let configuration = try load(
            """
            {"contracts": [{"callee": "subscribeNext", "template": "disposeBag", "tokenName": "the subscribeNext Disposable"}]}
            """
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: legacySource, path: "Legacy.swift").findings
        #expect(findings.map(\.rule) == [.combineSinkSelfCycle])
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.message.contains("the subscribeNext Disposable") == true)
    }

    @Test("A signalDisposable contract flags a strong-self subscription set into a member")
    func signalDisposableContract() throws {
        let configuration = try load(
            """
            {"contracts": [{"callee": "observe", "requiredLabels": ["each"], "template": "signalDisposable"}]}
            """
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: customSignalSource, path: "Watcher.swift").findings
        #expect(findings.map(\.rule) == [.combineSinkSelfCycle])
        #expect(findings.first?.message.contains("self → disposable → closure → self") == true)
    }
}
