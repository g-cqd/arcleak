// swift-format-ignore-file
import Foundation

// `Timer(timeInterval:target:selector:userInfo:repeats:)` is the unscheduled twin of `scheduledTimer`: once it is
// added to a run loop, the run loop keeps the timer and the timer keeps its target (or its block).
final class UnscheduledTimerTarget {
    var timer: Timer?

    func start() {
        timer = Timer(timeInterval: 2, target: self, selector: #selector(tick), userInfo: nil, repeats: true) // #al:expect timer-retains-self
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc func tick() {}
}

final class UnscheduledTimerBlock {
    var timer: Timer?

    func start() {
        timer = Timer(timeInterval: 2, repeats: true) { _ in self.tick() } // #al:expect timer-retains-self
        RunLoop.main.add(timer!, forMode: .common)
    }

    func tick() {}
}
