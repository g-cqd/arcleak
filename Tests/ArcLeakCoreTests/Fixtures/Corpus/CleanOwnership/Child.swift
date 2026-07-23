// swift-format-ignore-file
final class Child {
    weak var parent: Parent?
    unowned var owner: Parent

    init(owner: Parent) {
        self.owner = owner
    }
}