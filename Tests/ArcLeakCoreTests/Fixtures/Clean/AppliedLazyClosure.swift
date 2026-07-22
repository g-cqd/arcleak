// Immediately-applied initializer closures: the closure runs once and is
// released — nothing is stored. Classic naive-linter false positive.
final class Applied {
    let id = 3

    lazy var banner: String = {
        "ready \(self.id)"
    }()

    let constant: Int = {
        40 + 2
    }()
}
