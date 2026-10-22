// swift-format-ignore-file
import AVFoundation
import Foundation

// KVO observations that do not close a cycle: [weak self] in the handler, a
// handler that never touches self, and an observed object that self does not
// keep (a parameter).
final class QuietObserver: NSObject {
    let player = AVPlayer()
    var rateObservation: NSKeyValueObservation?
    var itemObservation: NSKeyValueObservation?
    var otherObservation: NSKeyValueObservation?

    func start(other: AVPlayer) {
        rateObservation = player.observe(\.rate) { [weak self] _, _ in
            self?.update()
        }
        itemObservation = player.observe(\.currentItem) { player, _ in
            print(player.rate)
        }
        otherObservation = other.observe(\.rate) { _, _ in
            self.update()
        }
    }

    func update() {}
}
