public import Foundation

/// Spawns short-lived subprocesses (`swift build`, `xcrun`) with a **scrubbed
/// environment** — only the allowlisted variables below are inherited from the
/// parent. This blocks environment-based influence (`DYLD_INSERT_LIBRARIES`,
/// `DEVELOPER_DIR`, `SWIFTPM_HOOKS_DIR`, `LD_LIBRARY_PATH`, …) over how the
/// child resolves toolchain binaries or libraries.
///
/// Lifted from SwiftStaticAnalysis, with one deliberate change: the original
/// enforced its wall-clock deadline with a GCD global-queue timer, which this
/// repo's `Scripts/no-gcd.sh` gate forbids. The watchdog is re-expressed as
/// structured concurrency — a `ContinuousClock` deadline polled in a
/// `TaskGroup` child that `terminate()`s the process — the same shape
/// `Experimental/SILConfirmationSession.runSILGen` already uses. `run` is
/// therefore `async`.
public enum ProcessExecutor {
    /// Environment variables inherited from the parent. Anything else is
    /// dropped — including `DYLD_INSERT_LIBRARIES`, `DEVELOPER_DIR`,
    /// `SWIFTPM_HOOKS_DIR`, all `LD_*` / `DYLD_*` overrides. Shell-related
    /// variables (`SHELL`, `BASH_ENV`) and IFS-style settings are excluded on
    /// purpose — historic privilege-escalation vectors.
    public static let allowedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL",
        "LC_CTYPE", "LC_MESSAGES", "TMPDIR", "TERM",
    ]

    /// Result of a subprocess invocation.
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        /// `true` if the process exited normally with code 0.
        public var succeeded: Bool { exitCode == 0 }
    }

    /// Errors raised by ``ProcessExecutor/run(executable:arguments:currentDirectory:environmentOverrides:timeout:)``.
    public enum Error: Swift.Error, Sendable {
        case launchFailed(executable: String, underlying: String)
        case timedOut(executable: String, after: Duration)
    }

    /// Default subprocess timeout. An unresponsive `swift`/`xcrun` past this
    /// point is hung and should be killed rather than stalling the analyzer.
    public static let defaultTimeout: Duration = .seconds(120)

    /// Run a subprocess with a scrubbed environment under a wall-clock deadline.
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the binary.
    ///   - arguments: Command-line arguments (the binary name is NOT prepended).
    ///   - currentDirectory: Optional working directory.
    ///   - environmentOverrides: Additional environment variables layered on top
    ///     of the allowlist.
    ///   - timeout: Maximum wall-clock time the child may run; afterwards it is
    ///     `terminate()`d and the call throws ``Error/timedOut(executable:after:)``.
    /// - Returns: stdout / stderr / exit code.
    /// - Throws: ``Error/launchFailed(executable:underlying:)`` if `Process.run()`
    ///   throws; ``Error/timedOut(executable:after:)`` if the deadline expires.
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environmentOverrides: [String: String] = [:],
        timeout: Duration = defaultTimeout
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd = currentDirectory {
            process.currentDirectoryURL = cwd
        }
        process.environment = scrubbedEnvironment(overrides: environmentOverrides)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw Error.launchFailed(
                executable: executable.path,
                underlying: error.localizedDescription
            )
        }

        // stdout and stderr are drained concurrently (a serial drain deadlocks
        // when the child fills the other pipe); a watchdog child terminates the
        // process past the deadline. When both drains hit EOF the child has
        // exited and closed its pipes, so the watchdog is cancelled.
        enum DrainEvent: Sendable {
            case out(Data)
            case err(Data)
            case timedOut
        }

        var stdoutData = Data()
        var stderrData = Data()
        var timedOut = false

        await withTaskGroup(of: DrainEvent.self) { group in
            group.addTask {
                .out(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
            group.addTask {
                .err(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
            group.addTask {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: timeout)
                while process.isRunning {
                    if clock.now >= deadline {
                        process.terminate()
                        return .timedOut
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return .timedOut  // sentinel; ignored once both drains complete
            }

            var drainsDone = 0
            for await event in group {
                switch event {
                case .out(let data):
                    stdoutData = data
                    drainsDone += 1
                case .err(let data):
                    stderrData = data
                    drainsDone += 1
                case .timedOut:
                    if process.isRunning { timedOut = true }
                }
                if drainsDone == 2 {
                    group.cancelAll()
                    break
                }
            }
        }

        process.waitUntilExit()

        if timedOut {
            throw Error.timedOut(executable: executable.path, after: timeout)
        }

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Compose the child environment from the allowlist plus explicit overrides.
    static func scrubbedEnvironment(
        overrides: [String: String] = [:],
        source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in allowedEnvironmentKeys {
            if let value = source[key] {
                env[key] = value
            }
        }
        for (key, value) in overrides {
            env[key] = value
        }
        return env
    }
}
