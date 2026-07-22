// A real finding intentionally silenced with the intent marker. The analyzer
// must suppress it (and surface it in the suppressed list, with the reason).
final class Deliberate {
    var onTick: (() -> Void)?

    func arm() {
        // arcleak:deliberate -- owner tears this down in shutdown(); lifetime is intentional
        onTick = { // arcleak-expect-suppressed: stored-closure-strong-self
            self.tick()
        }
    }

    func tick() {}
}
