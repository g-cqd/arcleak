// swift-format-ignore-file
import Combine
import Foundation
import UIKit
import XCTest

// Every case below is a real-world idiom that dogfooding on kickstarter,
// wikipedia-ios, and isowords proved must stay silent.

// 1. XCTest: token held across a synchronous wait; scope-end cancellation is
//    the intended teardown.
final class ViewModelTests: XCTestCase {
    let subject = PassthroughSubject<Int, Never>()

    func testEmitsValue() {
        var cancellables = Set<AnyCancellable>()
        let expectation = expectation(description: "emits")
        subject.sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        subject.send(1)
        waitForExpectations(timeout: 0.1)
    }
}

// 2. Process-lifetime owner + weak block observer: register-forever is
//    intentional; nothing is retained, removal is never needed.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var count = 0

    func register() {
        _ = NotificationCenter.default.addObserver(
            forName: Notification.Name("sessionStarted"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.count += 1
        }
    }
}

final class SettingsController {
    static let shared = SettingsController()
    var value = 0

    private init() {}

    func subscribe() {
        _ = NotificationCenter.default.addObserver(
            forName: Notification.Name("changed"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.value += 1
        }
    }
}

// 3. Synchronous-read idiom (implicit getter): the subscription's work
//    completes before scope end; `defer` extends the token's lifetime past the
//    read and scope-end cancellation is desired.
final class StateBox {
    let subject = CurrentValueSubject<Int, Never>(0)

    var currentValue: Int {
        var value = 0
        let cancellable = subject.sink { value = $0 }
        defer { _ = cancellable }
        return value
    }
}

// 4. Non-terminating task with a reachable cancel: managed lifecycle.
final class TipObserver {
    var task: Task<Void, Never>?

    func startObserving() {
        task = Task {
            while true {
                await refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopObserving() {
        task?.cancel()
        task = nil
    }

    func refresh() async {}
}