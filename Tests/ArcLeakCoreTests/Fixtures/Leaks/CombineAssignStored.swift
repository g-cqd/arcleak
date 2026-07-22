import Combine

// "The Subscribers.Assign instance created by this operator maintains a strong
// reference to object" — with a never-completing upstream and the cancellable
// stored on self, the cycle is closed.
final class Assigner {
    let subject = PassthroughSubject<Int, Never>()
    var cancellables = Set<AnyCancellable>()
    var latest = 0

    func bind() {
        subject.assign(to: \.latest, on: self) // arcleak-expect: combine-assign-self-cycle
            .store(in: &cancellables)
    }
}
