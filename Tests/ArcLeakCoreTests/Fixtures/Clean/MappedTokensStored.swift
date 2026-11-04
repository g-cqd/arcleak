// swift-format-ignore-file
import Foundation

// Observer tokens made by a `map` whose result is stored in a member, and removed in deinit: each token is stored.
final class MappedObservers {
    private var observers: [any NSObjectProtocol] = []

    init() {
        observers = [Notification.Name("a"), Notification.Name("b")]
            .map {
                NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                    self?.refresh()
                }
            }
    }

    func rearm() {
        self.observers = [Notification.Name("c")].compactMap({ name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refresh() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {}
}
