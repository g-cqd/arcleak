import Testing

/// In-process deinit canaries: fast, run-loop-free runtime checks that the
/// clean capture patterns deallocate and the cycle patterns provably don't.
/// The heavier anchor contracts (run loops, centers, sessions) live in the
/// `leak-oracle` executable.
func expectDeallocated<T: AnyObject>(
    _ comment: Comment? = nil,
    _ make: () -> T
) {
    weak var canary: T?
    do {
        let object = make()
        canary = object
        _ = object
    }
    #expect(canary == nil, comment ?? "object should have deallocated")
}

func expectLeaked<T: AnyObject>(
    _ comment: Comment? = nil,
    _ make: () -> T
) {
    weak var canary: T?
    do {
        let object = make()
        canary = object
        _ = object
    }
    #expect(canary != nil, comment ?? "object should still be alive (cycle expected)")
}

@Suite struct DeinitCanaryTests {
    final class StrongBox {
        var onChange: (() -> Void)?
        var value = 0
        func arm() { onChange = { self.value += 1 } }
    }

    final class WeakBox {
        var onChange: (() -> Void)?
        var value = 0
        func arm() { onChange = { [weak self] in self?.value += 1 } }
    }

    final class UnownedBlessed {
        let id = 7
        lazy var render: () -> String = { [unowned self] in "id=\(self.id)" }
    }

    @Test("strong stored closure provably cycles at runtime")
    func strongStoredClosureLeaks() {
        expectLeaked {
            let box = StrongBox()
            box.arm()
            return box
        }
    }

    @Test("weak stored closure deallocates")
    func weakStoredClosureDeallocates() {
        expectDeallocated {
            let box = WeakBox()
            box.arm()
            box.onChange?()
            return box
        }
    }

    @Test("book-blessed unowned same-lifetime closure deallocates")
    func unownedBlessedDeallocates() {
        expectDeallocated {
            let blessed = UnownedBlessed()
            _ = blessed.render()
            return blessed
        }
    }
}
