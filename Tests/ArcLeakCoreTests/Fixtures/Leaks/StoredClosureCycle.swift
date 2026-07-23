// swift-format-ignore-file
import Foundation

final class Box {
    var onChange: (() -> Void)?
    var value = 0

    func arm() {
        onChange = { // #al:expect stored-closure-strong-self
            self.value += 1
        }
        self.onChange = { [weak self] in
            self?.value += 1
        }
    }
}

final class Collector {
    var handlers: [() -> Void] = []
    var count = 0

    func register() {
        handlers.append { // #al:expect stored-closure-strong-self
            self.count += 1
        }
    }
}