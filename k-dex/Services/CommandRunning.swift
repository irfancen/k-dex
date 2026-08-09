import Foundation

/// The seam under every request/response subprocess call. Services go
/// through `Commands.runner`; production wires the system implementation
/// over ProcessRunner, tests inject fixtures — so everything above this line
/// (KubectlService, HelmService, OverviewService) is exercisable without a
/// kubectl binary or a cluster.
///
/// Streaming (watch, logs, port-forward) deliberately stays on ProcessRunner
/// directly: there the lifecycle — run tokens, EOF-driven teardown, the exit
/// watchdog — *is* the behavior under test, and a fixture seam would mock
/// away exactly what matters.
nonisolated protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> ProcessResult
}

nonisolated extension CommandRunning {
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        try await run(executable, arguments, stdin: nil)
    }

    /// Runs a command and throws if it exits non-zero. kubectl warnings on
    /// stderr are dropped from the error message so the real failure shows.
    @discardableResult
    func runChecked(_ executable: String, _ arguments: [String], stdin: Data? = nil) async throws -> ProcessResult {
        let result = try await run(executable, arguments, stdin: stdin)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            let stderr = result.stderrString
            let errors = stderr
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("warning:") }
                .joined(separator: "\n")
            throw ProcessError.failed(
                command: executable,
                exitCode: result.exitCode,
                // All-warnings stderr falls back whole: an empty error reads
                // as "no reason" when the warning was the reason.
                stderr: errors.isEmpty ? stderr : errors
            )
        }
        return result
    }
}

/// Production implementation: real subprocesses via ProcessRunner.
nonisolated struct SystemCommandRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> ProcessResult {
        try await ProcessRunner.run(executable, arguments, stdin: stdin)
    }
}

/// Process-wide injection point — one knob rather than per-service injection
/// because the services are static enums. Swapped only by tests, which
/// serialize around the mutation and restore the system runner.
nonisolated enum Commands {
    nonisolated(unsafe) static var runner: any CommandRunning = SystemCommandRunner()
}
