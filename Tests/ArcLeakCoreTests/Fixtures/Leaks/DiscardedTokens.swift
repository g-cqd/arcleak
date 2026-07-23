// swift-format-ignore-file
import Combine
import Foundation

final class Discards {
    let subject = PassthroughSubject<Int, Never>()

    func observeAndLoseImmediately() {
        _ = subject.sink { print($0) } // #al:expect unstored-lifetime-token
    }

    func observeIntoDoomedLocal() {
        let token = subject.sink { print($0) } // #al:expect token-stored-in-local
    }

    func observeIntoDoomedLocalSet() {
        var locals = Set<AnyCancellable>()
        subject.sink { print($0) } // #al:expect token-stored-in-local
            .store(in: &locals)
    }

    func kvo(object: Progress) {
        let observation = object.observe(\.fractionCompleted) { _, _ in } // #al:expect token-stored-in-local
    }
}