import Foundation

// [unowned self] in a run-loop-anchored closure: the timer outlives arbitrary
// objects, so the first fire after self deallocates traps.
final class Fragile {
    var count = 0

    func start() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in // arcleak-expect: unowned-outlives-owner
            self.count += 1
        }
    }
}
