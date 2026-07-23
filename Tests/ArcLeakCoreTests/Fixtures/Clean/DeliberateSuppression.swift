// swift-format-ignore-file
// A real finding intentionally silenced with the intent marker. The analyzer
// must suppress it (and surface it in the suppressed list, with the reason).
final class Deliberate {
    var onTick: (() -> Void)?

    func arm() {
        // @al:accept -- owner tears this down in shutdown(); lifetime is intentional
        onTick = { // #al:expect-suppressed stored-closure-strong-self
            self.tick()
        }
    }

    func tick() {}
}