// swift-format-ignore-file
// store(in:) into a protocol `{ get set }` requirement from a protocol
// extension: that is instance storage, not a local (dogfood-reported FP).
// The sinks are weak, so no cycle rule applies either.
import Combine
import Foundation

protocol SocketListening: AnyObject {
    var socketCancellables: Set<AnyCancellable> { get set }
    var feed: PassthroughSubject<String, Never> { get }
    func handle(_ message: String)
}

extension SocketListening {
    func startListening() {
        feed
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.handle(message)
            }
            .store(in: &socketCancellables)
    }
}
