// swift-format-ignore-file
import Dispatch

// self → source → handler → self: dispatch sources hold their handlers until
// replaced or cancelled, and no cancel() exists here.
final class Beeper {
    let source = DispatchSource.makeTimerSource()
    var beeps = 0

    func start() {
        source.setEventHandler { // #al:expect dispatch-source-cycle
            self.beeps += 1
        }
        source.activate()
    }
}