// swift-format-ignore-file
// Finite tasks extending self's lifetime briefly are NOT leaks (stay silent),
// and weak-self loops exit when self dies.
final class Saver {
    var saved = false

    func kick() {
        Task {
            await work()
            saved = true
        }
    }

    func work() async {}
}

final class Looper {
    func start() {
        Task { [weak self] in
            while true {
                guard let self else { return }
                await self.step()
            }
        }
    }

    func step() async {}
}