import Combine

// self → cancellables → AnyCancellable → sink closure → self.
final class Sinker {
    let subject = PassthroughSubject<Int, Never>()
    var cancellables = Set<AnyCancellable>()
    var latest = 0

    func bind() {
        subject.sink { value in // arcleak-expect: combine-sink-self-cycle
            self.latest = value
        }
        .store(in: &cancellables)
    }
}
