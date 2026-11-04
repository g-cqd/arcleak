// swift-format-ignore-file
import Foundation

// The same `map`, its result dropped or kept in a local: the tokens go with it.
final class MappedObserversDropped {
    func arm() {
        _ = [Notification.Name("a")].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in // #al:expect unstored-lifetime-token
                self?.refresh()
            }
        }
    }

    func armLocally() {
        let observers = [Notification.Name("b")].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in // #al:expect token-stored-in-local
                self?.refresh()
            }
        }
    }

    func refresh() {}
}
