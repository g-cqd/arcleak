// swift-format-ignore-file
// The owned-child shapes that do not close a cycle: [weak self], a child held
// only in a local, a weak child, and a member that is not a stored property
// of self.
final class Panel {
    var onTap: (() -> Void)?
}

final class Host {
    let panel = Panel()
    weak var parentPanel: Panel?
    var computedPanel: Panel { Panel() }

    func setUp() {
        panel.onTap = { [weak self] in
            self?.refresh()
        }
        let local = Panel()
        local.onTap = { self.refresh() }
        parentPanel?.onTap = { self.refresh() }
        computedPanel.onTap = { self.refresh() }
    }

    func refresh() {}
}
