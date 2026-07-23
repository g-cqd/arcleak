// swift-format-ignore-file
// Token factories: the sink's AnyCancellable is the function's *implicit
// return value* (SE-0255), so the caller owns storage — not a discard.
// Reduced from a dogfooded NotificationCenter facade whose helpers were the
// tool's only findings in a 571-file app, all three false.
import Combine
import Foundation

enum React {
    static func to(
        _ name: Notification.Name,
        _ action: @escaping (Notification) -> Void
    ) -> AnyCancellable {
        NotificationCenter.default.publisher(for: name)
            .receive(on: RunLoop.main)
            .sink(receiveValue: action)
    }
}

final class TokenVendor {
    let subject = PassthroughSubject<Int, Never>()

    func makeToken() -> AnyCancellable {
        subject.sink { print($0) }
    }

    var freshToken: AnyCancellable {
        subject.sink { print($0) }
    }

    var explicitGetter: AnyCancellable {
        get {
            subject.sink { print($0) }
        }
    }
}
