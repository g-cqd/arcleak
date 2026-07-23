// swift-format-ignore-file
// Correctly broken cycle: [weak self] with SE-0365 implicit self after
// `guard let self`. The rebound strong self lives only per-invocation.
final class Weakly {
    var onChange: (() -> Void)?
    var value = 0

    func arm() {
        onChange = { [weak self] in
            guard let self else { return }
            value += 1
        }
    }
}