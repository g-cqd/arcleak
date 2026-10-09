#if os(macOS)
    import ArcLeakCore
    import Foundation
    import Testing

    /// `ProcessExecutor.run` awaits the child's exit after both pipes drain. That
    /// wait once used `Process.waitUntilExit()`, whose run-loop wake-up is lost
    /// intermittently when it follows the concurrent drains: the child had exited
    /// and the test process still hung forever (the macOS CI "Build & test" step
    /// timing out at 30 minutes). One call rarely trips it, so this repeats the
    /// call; a regression shows as the suite never finishing.
    @Suite struct ProcessExecutorTests {
        @Test("Repeated short-lived children are reaped, each reporting its own status")
        func reapsEveryChild() async throws {
            for _ in 0..<200 {
                let succeeded = try await ProcessExecutor.run(
                    executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: ["--find", "swift"]
                )
                #expect(succeeded.succeeded)
                #expect(!succeeded.stdout.isEmpty)
            }

            let failed = try await ProcessExecutor.run(
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: []
            )
            #expect(failed.exitCode == 1)
        }
    }
#endif
