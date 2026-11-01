// swift-format-ignore-file
import Dispatch

// The usual way to build a source: configure a local, then keep it. The handler is on the source, the source is
// stored on self, and nothing cancels it, so self → source → handler → self.
final class AliasedSource {
    var source: DispatchSourceTimer?
    var ticks = 0

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { self.ticks += 1 } // #al:expect dispatch-source-cycle
        timer.resume()
        source = timer
    }
}
