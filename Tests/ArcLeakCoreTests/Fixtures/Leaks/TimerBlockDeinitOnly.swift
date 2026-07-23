// swift-format-ignore-file
import Foundation

// Run loop → timer → block → self, and the only invalidate() sits in deinit —
// which can never run while that chain holds self. Definite leak (error).
final class Ticker {
    var timer: Timer?
    var count = 0

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in // #al:expect timer-retains-self
            self.count += 1
        }
    }

    deinit {
        timer?.invalidate()
    }
}