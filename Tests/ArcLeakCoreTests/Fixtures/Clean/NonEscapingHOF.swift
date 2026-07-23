// swift-format-ignore-file
// Non-escaping higher-order functions cannot create cycles — the closure dies
// before the call returns.
final class Mapper {
    let items = [1, 2, 3]
    var total = 0

    func sum() {
        items.forEach { self.total += $0 }
        let doubled = items.map { self.scale($0) }
        total = doubled.reduce(0, +)
    }

    func scale(_ x: Int) -> Int { x * 2 }
}