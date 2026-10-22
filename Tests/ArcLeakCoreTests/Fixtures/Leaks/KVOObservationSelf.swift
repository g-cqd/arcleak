// swift-format-ignore-file
import AVFoundation
import Foundation

// self → NSKeyValueObservation → change handler → self. The observation
// invalidates only when deinited, which happens after self's deinit — never,
// inside the cycle. A public fix of this shape: wikipedia-ios@9db7aa718d.
// The observed object does not matter: the cycle runs through the
// observation, so observing a parameter closes it too.
final class PlayerObserver: NSObject {
    let player = AVPlayer()
    @objc dynamic var progress = 0.0
    var rateObservation: NSKeyValueObservation?
    var progressObservation: NSKeyValueObservation?
    var otherObservation: NSKeyValueObservation?

    func start() {
        rateObservation = player.observe(\.rate) { _, _ in // #al:expect kvo-observation-self-cycle
            self.update()
        }
        self.progressObservation = self.observe(\.progress, options: [.new], changeHandler: { _, _ in self.update() }) // #al:expect kvo-observation-self-cycle
    }

    func follow(_ other: AVPlayer) {
        otherObservation = other.observe(\.rate) { _, _ in // #al:expect kvo-observation-self-cycle
            self.update()
        }
    }

    func update() {}
}
