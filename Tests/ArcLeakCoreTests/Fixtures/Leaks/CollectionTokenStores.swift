// swift-format-ignore-file
import Combine
import Foundation
import UIKit

// A token handed to `append`, `insert` or a subscript of a collection that self stores is owned by self, as
// `.store(in: &bag)` is: the handler captures self strongly, so self → bag → token → handler → self.
final class AppendedSink {
    var bag: [AnyCancellable] = []
    let subject = PassthroughSubject<Int, Never>()
    var last = 0

    func bind() {
        bag.append(subject.sink { self.last = $0 }) // #al:expect combine-sink-self-cycle
    }
}

final class InsertedSink {
    var bag = Set<AnyCancellable>()
    let subject = PassthroughSubject<Int, Never>()
    var last = 0

    func bind() {
        bag.insert(subject.sink { self.last = $0 }) // #al:expect combine-sink-self-cycle
    }
}

final class SubscriptSink {
    var tokens: [String: AnyCancellable] = [:]
    let subject = PassthroughSubject<Int, Never>()
    var last = 0

    func bind() {
        tokens["a"] = subject.sink { self.last = $0 } // #al:expect combine-sink-self-cycle
    }
}

final class InsertedAssign {
    var bag = Set<AnyCancellable>()
    let subject = PassthroughSubject<Int, Never>()
    var last = 0

    func bind() {
        bag.insert(subject.assign(to: \.last, on: self)) // #al:expect combine-assign-self-cycle
    }
}

final class AppendedObservation {
    var observations: [NSKeyValueObservation] = []
    let view = UIView()
    var count = 0

    func watch() {
        observations.append(view.observe(\.frame) { _, _ in self.count += 1 }) // #al:expect kvo-observation-self-cycle
    }
}

final class AppendedTask {
    var tasks: [Task<Void, Never>] = []
    let stream = AsyncStream<Int> { _ in }

    func start() {
        tasks.append(Task { for await value in stream { self.handle(value) } }) // #al:expect task-nonterminating-self
    }

    func handle(_ value: Int) {}
}

// A collection that only the method holds dies with it, and so does what it owns: the sink is cancelled at once.
final class LocalCollectionSink {
    let subject = PassthroughSubject<Int, Never>()

    func bind() {
        var bag: [AnyCancellable] = []
        bag.append(subject.sink { print($0) }) // #al:expect token-stored-in-local
        _ = bag
    }
}
