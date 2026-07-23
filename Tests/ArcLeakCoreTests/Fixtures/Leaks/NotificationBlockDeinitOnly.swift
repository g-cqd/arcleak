// swift-format-ignore-file
import Foundation

// The center "strongly holds the copied block until you remove the observer
// registration" — and removal only exists in deinit, which never runs while
// the block holds self. Definite leak (error).
final class NoteObserver {
    var token: (any NSObjectProtocol)?

    func start() {
        token = NotificationCenter.default.addObserver(forName: Notification.Name("tick"), object: nil, queue: nil) { _ in // #al:expect notification-observer-leak
            self.handle()
        }
    }

    func handle() {}

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}