// Runs `/usr/bin/xcrun swiftc`, so this was always macOS-only in fact.
// Stating it keeps Process — a corelibs Foundation type — out of the
// Linux build, which is what lets the rest link FoundationEssentials.
#if os(macOS)
    import Foundation

    /// Per-run SILGen cache + hardened subprocess runner. One instance memoizes
    /// SILGen output by file, so N findings in one file compile it once, and every
    /// compile drains both pipes concurrently under a wall-clock deadline.
    ///
    /// An `actor` so the memo is data-race-free without ad-hoc locking; the
    /// concurrent pipe drain and the watchdog are structured `TaskGroup` children,
    /// so a hung compiler is bounded and killed — no GCD (the repo policy gate).
    public actor SILConfirmationSession {
        private let timeout: Duration
        private var cache: [String: SILGenOutput] = [:]

        public init(timeout: Duration = SILConfirmation.defaultTimeout) {
            self.timeout = timeout
        }

        public func confirmSelfCapture(file: String, line: Int) async -> SILConfirmation.Outcome {
            switch await silGen(file: file) {
            case .emitted(let output):
                return SILConfirmation.verdict(fromSIL: output[...], file: file, line: line)
            case .failed(let reason):
                return .unavailable(reason)
            }
        }

        private func silGen(file: String) async -> SILGenOutput {
            if let cached = cache[file] { return cached }
            let result = await Self.runSILGen(file: file, timeout: timeout)
            cache[file] = result
            return result
        }

        /// SILGen result: the dump on success, a reason string on failure.
        enum SILGenOutput: Sendable {
            case emitted(String)
            case failed(String)
        }

        /// Runs `xcrun swiftc -emit-silgen -g <file>`. stdout and stderr are drained
        /// concurrently (a serial drain deadlocks when swiftc fills the other pipe),
        /// and a watchdog child terminates the process past the deadline.
        private static func runSILGen(file: String, timeout: Duration) async -> SILGenOutput {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swiftc", "-emit-silgen", "-g", file]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let termination = ProcessTermination(watching: process)

            do {
                try process.run()
            } catch {
                return .failed("cannot launch swiftc: \(error)")
            }

            enum DrainEvent: Sendable {
                case out(Data)
                case err(Data)
                case timedOut
                case exited
            }

            var out = Data()
            var err = Data()
            var timedOut = false

            await withTaskGroup(of: DrainEvent.self) { group in
                group.addTask {
                    .out(outPipe.fileHandleForReading.readDataToEndOfFile())
                }
                group.addTask {
                    .err(errPipe.fileHandleForReading.readDataToEndOfFile())
                }
                group.addTask {
                    // Watchdog: both reads finish when the process exits and closes
                    // its pipes; if the deadline passes first, kill it.
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: timeout)
                    while process.isRunning {
                        if clock.now >= deadline {
                            // SIGTERM, grace, then SIGKILL — swiftc's frontend
                            // children hold the pipe write ends, so only killing the
                            // tree's root hard actually unblocks the drains.
                            process.terminate()
                            try? await Task.sleep(for: .seconds(2))
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                            }
                            return .timedOut
                        }
                        // Cancelled once both drains finish: the deadline did not
                        // fire, and the exit wait below reaps the child.
                        if Task.isCancelled { return .exited }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    return .exited
                }

                var drainsDone = 0
                for await event in group {
                    switch event {
                    case .out(let data):
                        out = data
                        drainsDone += 1
                    case .err(let data):
                        err = data
                        drainsDone += 1
                    case .timedOut:
                        // Deterministic: only the deadline path returns this; the
                        // old `isRunning` re-check raced the SIGTERM-ed exit.
                        timedOut = true
                    case .exited:
                        break
                    }
                    // Both pipes closed: stop the watchdog, but keep reading
                    // so a deadline it already hit is still recorded.
                    if drainsDone == 2 {
                        group.cancelAll()
                    }
                }
            }

            await termination.wait()
            if timedOut {
                return .failed("swiftc exceeded \(timeout) budget")
            }
            guard process.terminationStatus == 0 else {
                let firstError =
                    String(decoding: err, as: UTF8.self)
                    .split(separator: "\n").first.map(String.init) ?? "swiftc failed"
                return .failed(firstError)
            }
            return .emitted(String(decoding: out, as: UTF8.self))
        }
    }
#endif
