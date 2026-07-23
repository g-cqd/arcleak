// swift-format-ignore-file
// The Swift book's canonical HTMLElement cycle: a lazy stored closure property
// capturing self strongly.
final class HTMLElement {
    let name: String

    lazy var asHTML: () -> String = { // #al:expect stored-closure-strong-self
        "<\(self.name) />"
    }

    init(name: String) {
        self.name = name
    }
}