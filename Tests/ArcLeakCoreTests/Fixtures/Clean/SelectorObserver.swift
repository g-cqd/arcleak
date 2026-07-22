import Foundation

// Selector-based addObserver does NOT retain the observer — removing in deinit
// is fine here (deinit is reachable). Only the block-based variant retains.
final class SelectorObserver: NSObject {
    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handle),
            name: Notification.Name("tick"),
            object: nil
        )
    }

    @objc func handle() {}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
