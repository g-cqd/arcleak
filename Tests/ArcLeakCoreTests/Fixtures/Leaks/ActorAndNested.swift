// swift-format-ignore-file
// Actors are reference types — the same cycle rules apply.
actor Ledger {
    var onCommit: (() -> Void)?
    var entries = 0

    func arm() {
        onCommit = {  // #al:expect stored-closure-strong-self
            Task { await self.bump() }
        }
    }

    func bump() {
        entries += 1
    }
}

// Nesting inside an enum namespace must not confuse type attribution.
enum Namespace {
    final class Box {
        var handler: (() -> Void)?
        var value = 0

        func arm() {
            handler = {  // #al:expect stored-closure-strong-self
                self.value += 1
            }
        }
    }
}

// Alias captures carry the alias's strength: `[s = self]` is a strong capture.
final class AliasStrong {
    var onChange: (() -> Void)?

    func arm() {
        onChange = { [s = self] in s.fire() }  // #al:expect stored-closure-strong-self
    }

    func fire() {}
}