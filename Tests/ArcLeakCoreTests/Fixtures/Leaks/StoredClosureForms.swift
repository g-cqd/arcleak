// swift-format-ignore-file
import Foundation

// A closure stored on self through a subscript, a `+=` of array literals, `updateValue` or a conditional
// expression is the same self → storage → closure → self cycle as `handler = { self… }`.
final class SubscriptStoredClosure {
    var handlers: [String: () -> Void] = [:]

    func arm() {
        handlers["a"] = { self.fire() } // #al:expect stored-closure-strong-self
    }

    func fire() {}
}

final class UpdateValueStoredClosure {
    var handlers: [String: () -> Void] = [:]

    func arm() {
        handlers.updateValue({ self.fire() }, forKey: "a") // #al:expect stored-closure-strong-self
    }

    func fire() {}
}

final class ArrayLiteralStoredClosure {
    var callbacks: [() -> Void] = []

    func arm() {
        callbacks += [{ self.fire() }] // #al:expect stored-closure-strong-self
    }

    func fire() {}
}

final class TernaryStoredClosure {
    var onChange: (() -> Void)?
    let flag = true

    func arm() {
        onChange = flag ? { self.fire() } : nil // #al:expect stored-closure-strong-self
    }

    func fire() {}
}

final class OwnedChildSubscript {
    let toolbar = ToolbarBox()

    func arm() {
        self.toolbar.actions["x"] = { self.fire() } // #al:expect stored-closure-strong-self
    }

    func fire() {}
}

final class ToolbarBox {
    var actions: [String: () -> Void] = [:]
}
