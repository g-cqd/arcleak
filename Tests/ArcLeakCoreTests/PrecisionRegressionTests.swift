import ArcLeakCore
import Testing

/// Precision pins: every false-positive-prone shape is asserted twice — the
/// shape stays silent (or carries its corrected claim), and a positive
/// control proves the rule still fires on the genuine bug beside it.
@Suite struct PrecisionRegressionTests {
    private let analyzer = Analyzer()

    private func findings(_ source: String) -> [Finding] {
        analyzer.analyze(source: source, path: "case.swift").findings
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

    // MARK: - store(in:) ownership classification

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

    @Test("A local bag captured by an escaping closure flags the lifetime hedge")
    func escapingCapturedLocalBagFlagsHedged() {
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
        let tokenFindings = findings(source).filter { $0.rule == .tokenStoredInLocal }
        #expect(tokenFindings.count == 1)
        // The claim is closure-tied lifetime plus unbounded growth, not
        // "dies at scope end".
        #expect(tokenFindings.first?.message.contains("escaping closure captured") == true)
    }

    @Test("A store inside a non-escaping HOF still claims scope death")
    func forEachStoreStillFires() {
        let source = """
            import Combine
            final class EdgeA {
                let subject = PassthroughSubject<Int, Never>()
                func arm() {
                    var bag = Set<AnyCancellable>()
                    [1, 2, 3].forEach { _ in
                        subject.sink { _ = $0 }.store(in: &bag)
                    }
                }
            }
            """
        let tokenFindings = findings(source).filter { $0.rule == .tokenStoredInLocal }
        #expect(tokenFindings.count == 1)
        #expect(tokenFindings.first?.message.contains("dies at scope end") == true)
    }

    @Test("A store rooted at a dying local reference flags again")
    func localRefRootedStoreFires() {
        let source = """
            import Combine
            final class EdgeB {
                let subject = PassthroughSubject<Int, Never>()
                final class Holder { var bag = Set<AnyCancellable>() }
                func arm() {
                    let holder = Holder()
                    subject.sink { _ = $0 }.store(in: &holder.bag)
                }
            }
            """
        #expect(findings(source).contains { $0.rule == .tokenStoredInLocal })
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

    @Test("A sink self-cycle inside an XCTestCase subclass fires with test context")
    func xctestSinkCycleFiresWithTestContext() {
        // XCTest holds test instances for the run, so the leak is real
        // (instances never deinit); the note names the context so deliberate
        // assertion plumbing can be accepted.
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
        let sinkFindings = findings(source).filter { $0.rule == .combineSinkSelfCycle }
        #expect(sinkFindings.count == 1)
        #expect(sinkFindings.first?.note?.contains("XCTest") == true)
    }

    @Test("Strong self only in receiveCompletion is caught (strongest closure wins)")
    func receiveCompletionStrongSelfFires() {
        let source = """
            import Combine
            final class Completer {
                let subject = PassthroughSubject<Int, Never>()
                var cancellables = Set<AnyCancellable>()
                var done = false
                func bind() {
                    subject.sink(
                        receiveCompletion: { _ in self.done = true },
                        receiveValue: { [weak self] _ in _ = self }
                    )
                    .store(in: &cancellables)
                }
            }
            """
        #expect(findings(source).contains { $0.rule == .combineSinkSelfCycle })
    }

    // MARK: - Inferred token factories (same-file return types)

    @Test("Discarding a call to a member function returning AnyCancellable fires")
    func discardedFactoryCallFires() {
        let source = """
            import Combine
            final class Owner {
                let subject = PassthroughSubject<Int, Never>()
                func make() -> AnyCancellable {
                    subject.sink { _ = $0 }
                }
                func arm() {
                    make()
                    let extra = 1
                    _ = extra
                }
            }
            """
        #expect(findings(source).contains { $0.rule == .unstoredLifetimeToken })
    }

    @Test("Storing the factory result on the instance stays clean (positive control)")
    func storedFactoryCallIsClean() {
        let source = """
            import Combine
            final class Owner {
                let subject = PassthroughSubject<Int, Never>()
                var token: AnyCancellable?
                func make() -> AnyCancellable {
                    subject.sink { _ = $0 }
                }
                func arm() {
                    token = make()
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    // MARK: - SwiftData @Transient (real ARC storage on @Model)

    @Test("@Transient mutual strong properties on @Model types still cycle")
    func transientModelPairStillFires() {
        let source = """
            import SwiftData
            @Model final class NodeA {
                @Transient var peer: NodeB?
                init() {}
            }
            @Model final class NodeB {
                @Transient var node: NodeA?
                init() {}
            }
            """
        #expect(findings(source).contains { $0.rule == .mutualStrongProperties })
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
        // The `where` clause binds the init PARAMETER (shadowing the member),
        // and the only `self` is a nested Task's [weak self] — which still
        // forces the sink closure to capture self strongly (runtime-proved by
        // the nested_weak_task_sink oracle scenario; the compiler warns
        // implicit-strong-capture on this shape).
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

    @Test("The compiler-suggested [weak self = self] spelling still fires with the teaching message")
    func nestedExplicitAssignmentVariantFires() {
        // The compiler's ImplicitStrongCapture warning suggests explicitly
        // assigning the capture item to silence it; the outer strong capture
        // (and the cycle) is unchanged under that spelling.
        let source = """
            import Combine
            final class Feed {
                let subject = PassthroughSubject<Int, Never>()
                var cancellables = Set<AnyCancellable>()
                func bind() {
                    subject.sink { _ in
                        Task { [weak self = self] in _ = self }
                    }
                    .store(in: &cancellables)
                }
            }
            """
        let sinkFindings = findings(source).filter { $0.rule == .combineSinkSelfCycle }
        #expect(sinkFindings.count == 1)
        #expect(sinkFindings.first?.message.contains("nested closure's capture list") == true)
    }

    @Test("A nested aliased capture [weak s = self] still fires")
    func nestedAliasCaptureStillFires() {
        // A capture initializer is evaluated in the ENCLOSING scope, so its
        // `self` forces the outer strong capture like any other use.
        let source = """
            import Combine
            final class Feed {
                let subject = PassthroughSubject<Int, Never>()
                var cancellables = Set<AnyCancellable>()
                func bind() {
                    subject.sink { _ in
                        Task { [weak weakSelf = self] in _ = weakSelf }
                    }
                    .store(in: &cancellables)
                }
            }
            """
        #expect(findings(source).contains { $0.rule == .combineSinkSelfCycle })
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
