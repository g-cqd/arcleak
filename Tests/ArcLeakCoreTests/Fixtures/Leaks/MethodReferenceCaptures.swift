// swift-format-ignore-file
import Combine

// Bound method references are strong captures with no capture-list syntax —
// stored on self or handed to a token API they behave exactly like a
// strong-self closure.
final class Referencer {
    let subject = PassthroughSubject<Int, Never>()
    var cancellables = Set<AnyCancellable>()
    var handler: (() -> Void)?

    func armStored() {
        handler = self.fire  // #al:expect stored-closure-strong-self
    }

    func armSink() {
        subject.sink(receiveValue: handle)  // #al:expect combine-sink-self-cycle
            .store(in: &cancellables)
    }

    func fire() {}
    func handle(_ value: Int) {}
}

// A self-referencing local function passed as a value carries the same strong
// capture.
final class LocalFunctioner {
    let subject = PassthroughSubject<Int, Never>()
    var cancellables = Set<AnyCancellable>()
    var count = 0

    func arm() {
        func bump(_ value: Int) {
            self.count += value
        }
        subject.sink(receiveValue: bump)  // #al:expect combine-sink-self-cycle
            .store(in: &cancellables)
    }
}