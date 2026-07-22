import ArcLeakCore
import Testing

/// Adversarial checks of capture semantics through the public API — every case
/// here is a way naive linters get ARC wrong.
@Suite struct ExtractionBehaviorTests {
    private func findings(_ source: String) -> [Finding] {
        Analyzer().analyze(source: source, path: "test.swift").findings
    }

    @Test("SE-0269: explicit [self] in the capture list is still a strong capture")
    func explicitSelfCaptureListIsStrong() {
        let source = """
            final class Box {
                var handler: (() -> Void)?
                var value = 0
                func arm() {
                    handler = { [self] in value += 1 }
                }
            }
            """
        #expect(findings(source).map(\.rule) == [.storedClosureStrongSelf])
    }

    @Test("Alias capture [s = self] does not decide for `self` — body decides")
    func aliasCaptureDoesNotMask() {
        let source = """
            final class Box {
                var handler: (() -> Void)?
                func arm() {
                    handler = { [s = self] in s.fire(); self.fire() }
                }
                func fire() {}
            }
            """
        #expect(findings(source).map(\.rule) == [.storedClosureStrongSelf])
    }

    @Test("Unknown reference-ness (extension of external type) is skipped, not guessed")
    func externalExtensionSkipped() {
        let source = """
            extension SomeExternalController {
                func arm() {
                    handler = { self.fire() }
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("Task with explicit [weak self] and while-true is clean")
    func weakTaskLoopClean() {
        let source = """
            final class Looper {
                func start() {
                    Task { [weak self] in
                        while true {
                            guard let self else { return }
                            await self.step()
                        }
                    }
                }
                func step() async {}
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("Non-repeating timer block is clean (auto-invalidates after firing)")
    func oneShotTimerClean() {
        let source = """
            import Foundation
            final class OneShot {
                var value = 0
                func schedule() {
                    Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                        self.value += 1
                    }
                }
            }
            """
        #expect(findings(source).isEmpty)
    }

    @Test("Timer severity upgrades to error only when invalidate is deinit-only")
    func timerSeverityUpgrade() {
        let deinitOnly = """
            import Foundation
            final class A {
                var timer: Timer?
                func start() {
                    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.tick() }
                }
                func tick() {}
                deinit { timer?.invalidate() }
            }
            """
        let absent = """
            import Foundation
            final class B {
                func start() {
                    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.tick() }
                }
                func tick() {}
            }
            """
        #expect(findings(deinitOnly).map(\.severity) == [.error])
        #expect(findings(absent).map(\.severity) == [.warning])
    }

    @Test("Findings are deterministically ordered")
    func deterministicOrdering() {
        let source = """
            final class Multi {
                var a: (() -> Void)?
                var b: (() -> Void)?
                func arm() {
                    b = { self.fire() }
                    a = { self.fire() }
                }
                func fire() {}
            }
            """
        let first = findings(source)
        let second = findings(source)
        #expect(first == second)
        #expect(first.map(\.line) == first.map(\.line).sorted())
    }

    @Test("Malformed source still analyzes what parses (error-tolerant tree)")
    func malformedSourceDoesNotCrash() {
        let source = """
            final class Broken {
                var handler: (() -> Void)?
                func arm() {
                    handler = { self.fire() }
                func fire() {}
            """
        #expect(findings(source).map(\.rule) == [.storedClosureStrongSelf])
    }
}
