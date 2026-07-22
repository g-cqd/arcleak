import Foundation

// Selector form: "The timer maintains a strong reference to target until it
// (the timer) is invalidated" — and no invalidate() exists in this type.
final class LegacyTicker: NSObject {
    var fired = 0

    func start() {
        Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true) // arcleak-expect: timer-retains-self
    }

    @objc func tick() {
        fired += 1
    }
}
