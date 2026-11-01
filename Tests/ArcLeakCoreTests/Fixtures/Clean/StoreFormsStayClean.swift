// swift-format-ignore-file
import Combine
import Dispatch
import Foundation
import UIKit

// The same shapes with the cycle broken, or with nothing to break: they stay silent beside the leaks in Leaks/.
final class WeakSubscriptStore {
    var handlers: [String: () -> Void] = [:]
    func arm() { handlers["a"] = { [weak self] in self?.fire() } }
    func fire() {}
}

final class OtherObjectStore {
    func arm(into other: WeakSubscriptStore) { other.handlers["a"] = { self.fire() } }
    func fire() {}
}

final class WeakAppendedSink {
    var bag: [AnyCancellable] = []
    let subject = PassthroughSubject<Int, Never>()
    var last = 0
    func bind() { bag.append(subject.sink { [weak self] in self?.last = $0 }) }
}

final class FiniteSequencePublisher {
    var bag = Set<AnyCancellable>()
    var last = 0
    func bind() { [1, 2, 3].publisher.sink { self.last = $0 }.store(in: &bag) }
    func bindRange() { (0..<3).publisher.sink { self.last = $0 }.store(in: &bag) }
}

final class InvalidatedUnscheduledTimer {
    var timer: Timer?
    func start() { timer = Timer(timeInterval: 2, target: self, selector: #selector(tick), userInfo: nil, repeats: true) }
    func stop() { timer?.invalidate(); timer = nil }
    @objc func tick() {}
}

final class OneShotUnscheduledTimer {
    var timer: Timer?
    func start() { timer = Timer(timeInterval: 2, repeats: false) { _ in self.tick() } }
    func tick() {}
}

final class CancelledAliasedSource {
    var source: DispatchSourceTimer?
    var ticks = 0
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { self.ticks += 1 }
        timer.resume()
        source = timer
    }
    func stop() { source?.cancel() }
}

final class WeakAliasedSource {
    var source: DispatchSourceTimer?
    var ticks = 0
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.ticks += 1 }
        timer.resume()
        source = timer
    }
}

final class LocalOnlySource {
    var ticks = 0
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { self.ticks += 1 }
        timer.cancel()
    }
}
