// swift-format-ignore-file
import Foundation

// A type that wipes its key in deinit, kept alive by a stored closure that
// captures self: deinit never runs, so the key is never wiped. By default
// only the cycle is reported; with the opt-in security pack enabled,
// sec-cleanup-in-unreachable-deinit adds a note on the same line
// (OptInRulesTests).
final class KeyVault {
    var key = Data(count: 32)
    var onChange: (() -> Void)?

    func arm() {
        onChange = { // #al:expect stored-closure-strong-self
            self.rotate()
        }
    }

    func rotate() {}

    deinit {
        key.resetBytes(in: 0..<key.count)
    }
}
