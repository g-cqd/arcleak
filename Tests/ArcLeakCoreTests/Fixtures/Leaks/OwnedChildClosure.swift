// swift-format-ignore-file
// A closure stored on a child that self owns closes the same loop as one
// stored on self: self → toolbar → onTap → self. The fix is [weak self] in
// the closure, or clearing the callback once it has fired. Warning, not
// error: a child may drop its callback after firing.
final class Toolbar {
    var onTap: (() -> Void)?
    var actions: [() -> Void] = []
}

// A struct child is stored inline in self, closure included: self → style →
// onTap → self.
struct ToolbarStyle {
    var onTap: (() -> Void)?
}

final class Screen {
    let toolbar = Toolbar()
    var footer: Toolbar?
    var style = ToolbarStyle()
    var count = 0

    func setUp() {
        toolbar.onTap = { // #al:expect stored-closure-strong-self
            self.reload()
        }
        self.footer?.onTap = { self.reload() } // #al:expect stored-closure-strong-self
        self.toolbar.actions.append { // #al:expect stored-closure-strong-self
            self.count += 1
        }
        toolbar.onTap = reload // #al:expect stored-closure-strong-self
        style.onTap = { self.reload() } // #al:expect stored-closure-strong-self
    }

    func reload() {}
}
