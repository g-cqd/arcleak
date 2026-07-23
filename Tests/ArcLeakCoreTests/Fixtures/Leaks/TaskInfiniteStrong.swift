// swift-format-ignore-file
// Task.init is @_implicitSelfCapture: `poll()` below captures self strongly
// with no `self` token in source. The while-true body never completes, and the
// handle is stored on self — cancel() in deinit can never run. Cycle (error).
final class Poller {
    var task: Task<Void, Never>?

    func start() {
        task = Task { // #al:expect task-nonterminating-self
            while true {
                poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func poll() {}

    deinit {
        task?.cancel()
    }
}

// Fire-and-forget variant: no stored handle, still pins self forever (warning).
final class Streamer {
    func start() {
        Task { // #al:expect task-nonterminating-self
            for await value in makeStream() {
                self.consume(value)
            }
        }
    }

    func makeStream() -> AsyncStream<Int> {
        AsyncStream { _ in }
    }

    func consume(_ value: Int) {}
}