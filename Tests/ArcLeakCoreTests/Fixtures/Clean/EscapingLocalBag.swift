// swift-format-ignore-file
// A genuinely-local Set<AnyCancellable> captured by an escaping closure: the
// capture extends the box's lifetime past the function's return, so "dies at
// scope end" would be wrong (dogfood-reported FP: continuation-style bridge).
import Combine

enum Bridging {
    static func makeSender(subject: PassthroughSubject<Int, Never>) -> (Int) -> Void {
        var cancellables = Set<AnyCancellable>()
        let send: (Int) -> Void = { value in
            subject
                .sink { _ = $0 }
                .store(in: &cancellables)
            subject.send(value)
        }
        return send
    }
}
