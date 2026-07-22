import Dispatch
import Foundation
import UIKit

// Re-derived from the canonical community [weak self] scenario collections
// (Al Maleh's demo repo, LeakDetector's scenario app) — patterns those corpora
// prove must NOT be flagged. Re-implemented from the described semantics, not
// copied.

// Delayed deallocation ≠ leak: asyncAfter pins self only until it fires.
final class DelayedDeallocation {
    var value = 0

    func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            self.value += 1
        }
    }
}

// UIView.animate's closures are documented transient — strong self is fine.
final class AnimationOwner {
    let view = UIView()

    func fade() {
        UIView.animate(withDuration: 0.3) {
            self.view.alpha = 0
        }
    }
}

// Passing self as an argument (not capturing) retains only for the call.
final class Presenter {
    func present(in coordinator: Coordinator) {
        coordinator.register(presenter: self)
    }
}

final class Coordinator {
    weak var presenter: Presenter?

    func register(presenter: Presenter) {
        self.presenter = presenter
    }
}

// Semaphore-style one-shot continuation: strong self until signaled, then done.
final class OneShotWaiter {
    var result = 0

    func wait(on queue: DispatchQueue) {
        queue.async {
            self.result = 42
        }
    }
}
