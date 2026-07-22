import Foundation

// Repeating timer with strong self, but invalidate() is reachable outside
// deinit — the lifecycle is deliberately managed. Silent by design.
final class ManagedTicker {
    var timer: Timer?
    var count = 0

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.count += 1
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
