// `Process` is corelibs-style Foundation: macOS-only here, like its callers.
#if os(macOS)
    import Foundation

    /// An awaitable signal for a `Process` exiting, used in place of
    /// `Process.waitUntilExit()`.
    ///
    /// `waitUntilExit()` parks the calling thread in a run-loop wait that depends
    /// on a wake-up from the process-exit notification. Called from async code,
    /// after the pipe drains have already seen EOF, that wake-up can be lost: the
    /// child is gone, yet the thread (a cooperative-pool thread, so the whole test
    /// run) never returns. A `terminationHandler` is invoked from the exit
    /// notification itself and needs no run loop, so the exit is awaited as a
    /// suspension instead.
    struct ProcessTermination: Sendable {
        private let exits: AsyncStream<Void>

        /// Installs the termination handler on `process`.
        /// - Precondition: call before `process.run()`; the handler is fixed once
        ///   the process is running.
        init(watching process: Process) {
            let (exits, signal) = AsyncStream<Void>.makeStream()
            process.terminationHandler = { _ in
                signal.yield()
                signal.finish()
            }
            self.exits = exits
        }

        /// Suspends until the watched process has exited (returns at once if it
        /// already has). `terminationStatus` is valid afterwards.
        func wait() async {
            for await _ in exits {}
        }
    }
#endif
