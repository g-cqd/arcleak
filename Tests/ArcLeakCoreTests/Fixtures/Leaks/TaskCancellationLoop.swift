// swift-format-ignore-file
import Foundation

// `while !Task.isCancelled` ends only when something cancels the task. The task keeps self, so nothing in deinit
// can cancel it, and with no other cancel() in the type nothing ever does.
final class PollingStored {
    var polling: Task<Void, Never>?

    func start() {
        polling = Task { // #al:expect task-nonterminating-self
            while !Task.isCancelled { await self.poll() }
        }
    }

    func poll() async {}
}

final class PollingDetached {
    var polling: Task<Void, Never>?

    func start() {
        polling = Task.detached { // #al:expect task-nonterminating-self
            while Task.isCancelled == false { await self.poll() }
        }
    }

    func poll() async {}
}
