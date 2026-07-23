// swift-format-ignore-file
// The "nested closure trap": the outer stored closure has no capture list, and
// the inner closure's `[weak self]` still forces the OUTER closure to capture
// self strongly (it must hold self to build the inner weak binding at run time).
final class Trap {
    var stored: (() -> Void)?

    func arm() {
        stored = { // #al:expect stored-closure-strong-self
            let inner = { [weak self] in
                self?.fire()
            }
            inner()
        }
    }

    func fire() {}
}