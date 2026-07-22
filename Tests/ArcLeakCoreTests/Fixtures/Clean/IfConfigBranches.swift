// Facts follow the active `#if` clause. Under the default configuration the
// custom condition is unset, so only the weak-capture branch exists — silent.
// (The IfConfigTests suite proves the flip: with the define set, the strong
// branch is analyzed and flagged.)
final class Platformy {
    var handler: (() -> Void)?

    func arm() {
        #if ARCLEAK_TEST_STRONG_BRANCH
            handler = { self.fire() }
        #else
            handler = { [weak self] in self?.fire() }
        #endif
    }

    func fire() {}
}
