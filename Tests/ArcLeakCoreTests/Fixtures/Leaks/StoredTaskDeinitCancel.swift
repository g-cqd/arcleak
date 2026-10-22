// swift-format-ignore-file
// A finite task that awaits, stored on self, whose only cancel() sits in
// deinit: deinit cannot run while the task holds self, so the cancel never
// fires and self lives as long as the awaited work — forever if it never
// returns. Same deinit-only idiom as Leaks/TimerBlockDeinitOnly (warning).
final class ProfileLoader {
    var loader: Task<Void, Never>?

    func start() {
        loader = Task { // #al:expect task-nonterminating-self
            await self.load()
        }
    }

    func load() async {}

    deinit {
        loader?.cancel()
    }
}

// Task.init is @_implicitSelfCapture: `fetch()` and `apply` capture self.
final class FeedRefresher {
    var task: Task<Void, Never>?

    func refresh() {
        self.task = Task { // #al:expect task-nonterminating-self
            let items = await fetch()
            apply(items)
        }
    }

    func fetch() async -> [Int] { [] }
    func apply(_ items: [Int]) {}

    deinit {
        task?.cancel()
    }
}
