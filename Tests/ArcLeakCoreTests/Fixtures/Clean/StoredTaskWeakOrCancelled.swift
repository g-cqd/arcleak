// swift-format-ignore-file
// Stored finite tasks that do not pin self: [weak self]; a cancel() reachable
// outside deinit; a body with nothing to await; a handle self does not keep.
final class WeakLoader {
    var loader: Task<Void, Never>?

    func start() {
        loader = Task { [weak self] in
            await self?.load()
        }
    }

    func load() async {}

    deinit {
        loader?.cancel()
    }
}

final class StoppableLoader {
    var loader: Task<Void, Never>?

    func start() {
        loader = Task {
            await self.load()
        }
    }

    func stop() {
        loader?.cancel()
    }

    func load() async {}

    deinit {
        loader?.cancel()
    }
}

final class SyncWorker {
    var job: Task<Void, Never>?
    var done = false

    func start() {
        job = Task {
            self.done = true
        }
    }

    deinit {
        job?.cancel()
    }
}

final class FireAndForget {
    func start() {
        Task {
            await self.load()
        }
    }

    func load() async {}

    deinit {}
}
