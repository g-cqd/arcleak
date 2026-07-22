import Combine
import Foundation

// The naive-linter gauntlet: every case is a true negative a sloppy tool
// flags. This file is the "does not fail stupidly" contract — zero findings,
// gated both directions by the fixture runner.

// 1. Local shadowing a member: the bare assignment writes the LOCAL.
final class Shadowed {
    var handler: (() -> Void)?

    func rehearse() {
        var handler: (() -> Void)?
        handler = { self.fire() }
        handler?()
    }

    func fire() {}
}

// 2. Parameter shadowing a member.
final class ParameterShadow {
    var completion: (() -> Void)?

    func run(completion: (() -> Void)?) {
        var completion = completion
        completion = { self.fire() }
        completion?()
    }

    func fire() {}
}

// 3. Computed property returning a fresh closure — nothing is stored.
final class ComputedClosure {
    var onTap: () -> Void {
        { self.fire() }
    }

    func fire() {}
}

// 4. Static stored closure: no instance `self` exists to capture.
final class StaticClosure {
    static var onBoot: () -> Void = { print("boot") }
}

// 5. Assigning to ANOTHER object's member is not self-storage.
final class Wirer {
    func wire(into panel: Panel) {
        panel.handler = { self.fire() }
    }

    func fire() {}
}

final class Panel {
    var handler: (() -> Void)?
}

// 6. Weak alias capture: `s` is a weak box; nothing strong.
final class AliasWeak {
    var onChange: (() -> Void)?

    func arm() {
        onChange = { [weak s = self] in s?.fire() }
    }

    func fire() {}
}

// 7. Extension of a protocol name: reference-ness unknowable — never guessed.
protocol Configurable: AnyObject {
    var onChange: (() -> Void)? { get set }
    func fire()
}

extension Configurable {
    func armDefault() {
        onChange = { [weak self] in self?.fire() }
    }
}

// 8. Finite detached task: lifetime extension, not a leak.
final class DetachedWorker {
    func kick() {
        Task.detached {
            await self.work()
        }
    }

    func work() async {}
}

// 9. Non-repeating timer auto-invalidates after firing.
final class OneShotTimer {
    var fired = false

    func schedule() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            self.fired = true
        }
    }
}

// 10. Block observer with removal on a reachable lifecycle path.
final class ManagedObserver {
    var token: (any NSObjectProtocol)?
    var count = 0

    func start() {
        token = NotificationCenter.default.addObserver(
            forName: Notification.Name("tick"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.count += 1
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

// 11. Cancellable rebound into a fresh set that IS instance storage.
final class RebindingSinker {
    let subject = PassthroughSubject<Int, Never>()
    var cancellables = Set<AnyCancellable>()
    var latest = 0

    func bind() {
        subject.sink { [weak self] value in
            self?.latest = value
        }
        .store(in: &cancellables)
    }
}
