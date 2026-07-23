// swift-format-ignore-file
// A local Set<AnyCancellable> captured by an escaping closure: the box lives
// exactly as long as the closure, and nothing ever removes entries — every
// invocation grows the set (recall-first: flagged with the lifetime hedge,
// not a false "dies at scope end" and not silence).
import Combine

enum Bridging {
    static func makeSender(subject: PassthroughSubject<Int, Never>) -> (Int) -> Void {
        var cancellables = Set<AnyCancellable>()
        let send: (Int) -> Void = { value in
            subject // #al:expect token-stored-in-local
                .sink { _ = $0 }
                .store(in: &cancellables)
            subject.send(value)
        }
        return send
    }
}
