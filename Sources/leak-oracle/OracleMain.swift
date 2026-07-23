import Foundation

#if !os(macOS)
    @main
    enum OracleMain {
        static func main() {
            print("leak-oracle is macOS-only (leaks tool + Darwin frameworks)")
            exit(64)
        }
    }
#else

    /// Runtime ground-truth oracle. Each scenario reproduces one knowledge-base
    /// retention contract at runtime:
    ///
    /// - **Cycle scenarios** construct an unreachable retain cycle and exit; the
    ///   `leaks -atExit` tool judges them (leaks expected for Leak scenarios,
    ///   zero for Clean ones).
    /// - **Contract scenarios** self-verify anchor behavior (run loops, centers,
    ///   sessions, sources, tasks hold objects until release) with run-loop
    ///   control and polling, exiting 0 when the documented contract held.
    ///
    /// A contract failure here means the OS changed behavior under arcleak's
    /// rules — CI goes red before users are misled.
    @main
    enum OracleMain {
        static func main() {
            let arguments = CommandLine.arguments
            guard arguments.count == 2 else {
                print("usage: leak-oracle <scenario>|list")
                exit(64)
            }
            let name = arguments[1]

            if name == "list" {
                for scenario in OracleScenarios.cyclesExpectedToLeak.keys.sorted() {
                    print("leak-cycle \(scenario)")
                }
                for scenario in OracleScenarios.cyclesExpectedClean.keys.sorted() {
                    print("clean-cycle \(scenario)")
                }
                for scenario in OracleScenarios.contracts.keys.sorted() {
                    print("contract \(scenario)")
                }
                exit(0)
            }

            if let scenario = OracleScenarios.cyclesExpectedToLeak[name]
                ?? OracleScenarios.cyclesExpectedClean[name]
            {
                scenario()
                exit(0)
            }
            if let contract = OracleScenarios.contracts[name] {
                exit(contract() ? 0 : 1)
            }
            print("unknown scenario: \(name)")
            exit(64)
        }
    }

    enum OracleSupport {
        /// `RunLoop.run(until:)` is Date-based by API; the interval is short and
        /// relative, so wall-clock jumps are immaterial here.
        static func spinRunLoop(seconds: TimeInterval) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        }

        /// Polls (spinning the run loop) until `condition` holds or the timeout
        /// elapses — release assertions must tolerate asynchronous teardown.
        /// Deadline math uses the monotonic clock: timeouts must not stretch or
        /// shrink when wall-clock time is adjusted.
        static func waitUntil(timeout: Duration, _ condition: () -> Bool) -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if condition() { return true }
                spinRunLoop(seconds: 0.05)
            }
            return condition()
        }
    }
#endif
