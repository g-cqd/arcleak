// swift-format-ignore-file
import Combine
import Dispatch
import Foundation

// URLSession with delegate but invalidation reachable from shutdown() — managed.
final class ManagedApi: NSObject, URLSessionDelegate {
    var session: URLSession?

    func start() {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func shutdown() {
        session?.finishTasksAndInvalidate()
    }
}

// Dispatch source with a weak handler and reachable cancel() — managed.
final class ManagedBeeper {
    let source = DispatchSource.makeTimerSource()
    var beeps = 0

    func start() {
        source.setEventHandler { [weak self] in
            self?.beeps += 1
        }
        source.activate()
    }

    func stop() {
        source.cancel()
    }
}

// [unowned self] in a cancellable stored on self: the subscription dies with
// self (same lifetime), so unowned is the book-blessed shape — silent.
final class SameLifetime {
    let subject = PassthroughSubject<Int, Never>()
    var cancellables = Set<AnyCancellable>()
    var latest = 0

    func bind() {
        subject.sink { [unowned self] value in
            self.latest = value
        }
        .store(in: &cancellables)
    }
}