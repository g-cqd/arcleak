// swift-format-ignore-file
// A home-grown event bus whose subscribe(_:) returns an opaque token. For
// subscribe, bind and drive the built-in reactive template needs the RxSwift
// bag spelling (.disposed(by:) or addDisposableTo(_:)); a token assigned to a
// member of self is not provably a Disposable that keeps the closure. Here the
// bus keeps the handler and stop() unsubscribes it: a managed lifecycle.
final class EventBus {
    static let shared = EventBus()
    private var handlers: [Int: (String) -> Void] = [:]
    private var nextID = 0

    func subscribe(_ handler: @escaping (String) -> Void) -> Int {
        nextID += 1
        handlers[nextID] = handler
        return nextID
    }

    func unsubscribe(_ id: Int) {
        handlers[id] = nil
    }
}

final class InboxViewModel {
    var token: Int?
    var unread = 0

    func start() {
        token = EventBus.shared.subscribe { _ in self.unread += 1 }
    }

    func stop() {
        if let token { EventBus.shared.unsubscribe(token) }
    }
}
