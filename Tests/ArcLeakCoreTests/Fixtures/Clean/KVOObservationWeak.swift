// swift-format-ignore-file
import AVFoundation
import Foundation

// KVO observations that do not close a cycle: [weak self] in the handler,
// and a handler that never touches self.
final class QuietObserver: NSObject {
    let player = AVPlayer()
    var rateObservation: NSKeyValueObservation?
    var itemObservation: NSKeyValueObservation?

    func start() {
        rateObservation = player.observe(\.rate) { [weak self] _, _ in
            self?.update()
        }
        itemObservation = player.observe(\.currentItem) { player, _ in
            print(player.rate)
        }
    }

    func update() {}
}

// A managed lifecycle: stop() invalidates and releases the observation from a
// reachable path, which drops the handler and with it the hold on self.
final class ManagedObserver: NSObject {
    let player = AVPlayer()
    var rateObservation: NSKeyValueObservation?

    func start() {
        rateObservation = player.observe(\.rate) { _, _ in
            self.update()
        }
    }

    func stop() {
        rateObservation?.invalidate()
        rateObservation = nil
    }

    func update() {}
}
