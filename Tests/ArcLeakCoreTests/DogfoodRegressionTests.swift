import ArcLeakCore
import Testing

/// Precision regressions from dogfooding real apps. Every false-positive fix
/// is pinned twice: the FP shape stays silent, and a positive control proves
/// the rule still fires on the genuine bug next door.
@Suite struct DogfoodRegressionTests {
    private let analyzer = Analyzer()

    private func findings(_ source: String) -> [Finding] {
        analyzer.analyze(source: source, path: "dogfood.swift").findings
    }

    // MARK: - Implicit-return token factories (SE-0255)

    @Test("Single-expression factory returning a sink token is not a discard")
    func factoryImplicitReturnIsClean() {
        let source = """
            import Combine
            enum React {
                static func to(_ subject: PassthroughSubject<Int, Never>) -> AnyCancellable {
                    subject
                        .receive(on: RunLoop.main)
                        .sink { _ in }
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("Shorthand and explicit getters returning a token are not discards")
    func getterImplicitReturnIsClean() {
        let source = """
            import Combine
            final class Vendor {
                let subject = PassthroughSubject<Int, Never>()
                var short: AnyCancellable {
                    subject.sink { _ in }
                }
                var explicit: AnyCancellable {
                    get {
                        subject.sink { _ in }
                    }
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("A sink discarded in a Void method still fires (positive control)")
    func discardedSinkStillFires() {
        let source = """
            import Combine
            final class Box {
                let subject = PassthroughSubject<Int, Never>()
                func arm() {
                    subject.sink { _ in }
                }
            }
            """
        #expect(findings(source).contains { $0.rule == .unstoredLifetimeToken })
    }

    @Test("A sink that is not the body's only statement stays a discard")
    func nonFinalStatementSinkStillFires() {
        let source = """
            import Combine
            final class Box {
                let subject = PassthroughSubject<Int, Never>()
                func arm() -> Int {
                    subject.sink { _ in }
                    return 1
                }
            }
            """
        #expect(findings(source).contains { $0.rule == .unstoredLifetimeToken })
    }

    // MARK: - Parameter shadowing of member-method names

    @Test("Setter parameter shadowing a method name is not a bound method reference")
    func setterParameterShadowingIsClean() {
        let source = """
            final class SelectionState {
                private var defaultColor: Int = 0
                func color(for value: Int) -> Int { value }
                func setDefaultColor(_ color: Int) {
                    defaultColor = color
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("Init parameter sharing a static factory's name is not a bound method reference")
    func initParameterShadowingIsClean() {
        let source = """
            final class CachedTirage {
                var compositeId: String
                init(compositeId: String) {
                    self.compositeId = compositeId
                }
                static func compositeId(sourceId: String, id: Int) -> String {
                    "\\(sourceId)#\\(id)"
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("A bare static method name assigned in instance context is not a self capture")
    func staticMethodValueIsClean() {
        let source = """
            final class Box {
                var transform: ((Int) -> String)?
                func arm() {
                    transform = format
                }
                static func format(_ value: Int) -> String { "\\(value)" }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("A real bound method reference stored in a property still fires (positive control)")
    func boundMethodReferenceStillFires() {
        let source = """
            final class Box {
                var handler: (() -> Void)?
                func arm() {
                    handler = tick
                }
                func tick() {}
            }
            """
        #expect(findings(source).contains { $0.rule == .storedClosureStrongSelf })
    }

    // MARK: - SwiftData @Model exemption

    @Test("A @Model relationship pair produces no mutual-strong finding")
    func modelPairIsClean() {
        let source = """
            import SwiftData
            @Model final class Source {
                var items: [Item] = []
                init() {}
            }
            @Model final class Item {
                var source: Source?
                init() {}
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("A plain mutual strong pair still fires (positive control)")
    func plainMutualPairStillFires() {
        let source = """
            final class Parent {
                var children: [Child] = []
            }
            final class Child {
                var parent: Parent?
            }
            """
        #expect(findings(source).contains { $0.rule == .mutualStrongProperties })
    }

    // MARK: - store(in:) ownership classification (field report, 2603-file app)

    @Test("store(in:) into a protocol { get set } requirement is instance storage")
    func protocolRequirementStoreIsClean() {
        let source = """
            import Combine
            protocol Listening: AnyObject {
                var bag: Set<AnyCancellable> { get set }
                var feed: PassthroughSubject<Int, Never> { get }
            }
            extension Listening {
                func start() {
                    feed.sink { [weak self] _ in _ = self }
                        .store(in: &bag)
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("store(in:) through a non-self reference makes no scope-death claim")
    func nonSelfReferenceStoreIsClean() {
        let source = """
            import Combine
            final class Coordinator { var bag = Set<AnyCancellable>() }
            struct Context { let coordinator: Coordinator }
            enum Wiring {
                static func wire(subject: PassthroughSubject<Int, Never>, context: Context) {
                    subject.sink { _ = $0 }
                        .store(in: &context.coordinator.bag)
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("A local bag captured by an escaping closure makes no scope-death claim")
    func escapingCapturedLocalBagIsClean() {
        let source = """
            import Combine
            enum Bridge {
                static func makeSender(subject: PassthroughSubject<Int, Never>) -> (Int) -> Void {
                    var bag = Set<AnyCancellable>()
                    let send: (Int) -> Void = { value in
                        subject.sink { _ = $0 }.store(in: &bag)
                        subject.send(value)
                    }
                    return send
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("An unknown bare store target (out-of-file superclass member) makes no claim")
    func unknownBareStoreTargetIsClean() {
        let source = """
            import Combine
            final class Child: ExternalBase {
                let subject = PassthroughSubject<Int, Never>()
                func bind() {
                    subject.sink { _ = $0 }.store(in: &inheritedBag)
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("A local bag stored at its own scope still fires (positive control)")
    func sameScopeLocalStoreStillFires() {
        let source = """
            import Combine
            final class Box {
                let subject = PassthroughSubject<Int, Never>()
                func arm() {
                    var bag = Set<AnyCancellable>()
                    subject.sink { _ = $0 }.store(in: &bag)
                }
            }
            """
        #expect(findings(source).contains { $0.rule == .tokenStoredInLocal })
    }

    // MARK: - Sink cycles: XCTest noise and the nested-capture-list trap

    @Test("A sink self-cycle inside an XCTestCase subclass is silenced")
    func xctestSinkCycleSilenced() {
        let source = """
            import Combine
            import XCTest
            final class QueueTests: XCTestCase {
                let subject = PassthroughSubject<Int, Never>()
                var cancellables = Set<AnyCancellable>()
                var result: [Int] = []
                func testDelivery() {
                    subject.sink { self.result.append($0) }
                        .store(in: &cancellables)
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("The same sink cycle outside a test class still fires (positive control)")
    func nonTestSinkCycleStillFires() {
        let source = """
            import Combine
            final class Collector {
                let subject = PassthroughSubject<Int, Never>()
                var cancellables = Set<AnyCancellable>()
                var result: [Int] = []
                func bind() {
                    subject.sink { self.result.append($0) }
                        .store(in: &cancellables)
                }
            }
            """
        #expect(findings(source).contains { $0.rule == .combineSinkSelfCycle })
    }

    @Test("Nested Task [weak self] inside a sink fires with the teaching message")
    func nestedWeakTaskSinkFiresWithTeachingMessage() {
        // The field-report shape verbatim: `where`-clause binds the init
        // PARAMETER (shadowing the member), and the only `self` is a nested
        // Task's [weak self] — which still forces the sink closure to capture
        // self strongly (runtime-proved by the nested_weak_task_sink oracle
        // scenario; the 6.4 compiler now warns implicit-strong-capture here).
        let source = """
            import Combine
            final class ViewModel {
                private let assetId: Int
                var cancellables = Set<AnyCancellable>()
                init(assetId: Int, publisher: AnyPublisher<Int, Never>) {
                    self.assetId = assetId
                    publisher
                        .sink { id in
                            guard id == assetId else { return }
                            Task { [weak self] in _ = self }
                        }
                        .store(in: &cancellables)
                }
            }
            """
        let sinkFindings = findings(source).filter { $0.rule == .combineSinkSelfCycle }
        #expect(sinkFindings.count == 1)
        #expect(sinkFindings.first?.message.contains("nested closure's capture list") == true)
    }

    @Test("A direct strong sink keeps the plain message (no nested-trap addendum)")
    func directStrongSinkKeepsPlainMessage() {
        let source = """
            import Combine
            final class Plain {
                let subject = PassthroughSubject<Int, Never>()
                var cancellables = Set<AnyCancellable>()
                var value = 0
                func bind() {
                    subject.sink { self.value = $0 }
                        .store(in: &cancellables)
                }
            }
            """
        let sinkFindings = findings(source).filter { $0.rule == .combineSinkSelfCycle }
        #expect(sinkFindings.count == 1)
        #expect(sinkFindings.first?.message.contains("nested closure's capture list") == false)
    }
}
