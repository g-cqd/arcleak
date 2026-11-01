// swift-format-ignore-file
import Foundation

final class PollingStopped {
    var polling: Task<Void, Never>?
    func start() { polling = Task { while !Task.isCancelled { await self.poll() } } }
    func stop() { polling?.cancel() }
    func poll() async {}
}

final class PollingWeak {
    var polling: Task<Void, Never>?
    func start() { polling = Task { [weak self] in while !Task.isCancelled { await self?.poll() } } }
    func poll() async {}
}

final class PollingBounded {
    var polling: Task<Void, Never>?
    func start() { polling = Task { var n = 0; while !Task.isCancelled && n < 3 { await self.poll(); n += 1 } } }
    func poll() async {}
}
