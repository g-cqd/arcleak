// The Swift book's blessed pattern: [unowned self] on a closure stored on self
// that can never outlive self — "the closure and the instance … will always be
// deallocated at the same time". Must NOT be flagged.
final class Blessed {
    let id = 7

    lazy var render: () -> String = { [unowned self] in
        "id=\(self.id)"
    }
}
