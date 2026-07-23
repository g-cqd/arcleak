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
}
