// swift-format-ignore-file
import Combine
import Foundation

// Strong-self sinks over provably finite pipelines are transient keep-alives,
// not cycles: Subscribers.Sink releases its closures on the terminal event.
// Dogfooding (kickstarter Paginator, wikipedia CLI) proved these must stay
// silent.
final class OneShotFetcher {
    var cancellables = Set<AnyCancellable>()
    var payload = Data()

    func fetch(url: URL) {
        URLSession.shared.dataTaskPublisher(for: url)
            .map(\.data)
            .replaceError(with: Data())
            .sink { data in
                self.payload = data
            }
            .store(in: &cancellables)
    }

    func constant() {
        Just(42)
            .sink { value in
                self.payload = Data([UInt8(value)])
            }
            .store(in: &cancellables)
    }

    func boundedSubject(subject: PassthroughSubject<Int, Never>) {
        subject
            .first()
            .sink { value in
                self.payload = Data([UInt8(value)])
            }
            .store(in: &cancellables)
    }
}