import Foundation
import Testing
@testable import K_Dex

/// Thread-safe capture box for exit callbacks arriving on arbitrary queues.
private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (code: Int32, stderr: String)?

    func set(_ code: Int32, _ stderr: String) {
        lock.lock(); defer { lock.unlock() }
        if value == nil { value = (code, stderr) }
    }

    func get() -> (code: Int32, stderr: String)? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// Pins the streamed-process teardown: EOF-driven onExit ordering (finding 7)
// and the residual-B watchdog — a grandchild that inherits the pipe
// write-ends must not wedge onExit forever.
struct ProcessRunnerStreamTests {
    private func awaitExit(_ box: ExitBox, upTo seconds: Double) async throws -> (code: Int32, stderr: String)? {
        for _ in 0..<Int(seconds * 10) {
            if let result = box.get() { return result }
            try await Task.sleep(for: .milliseconds(100))
        }
        return box.get()
    }

    /// Normal path: exit fires promptly once both pipes hit EOF, with stderr
    /// fully drained — never truncated (finding 7's original failure).
    @Test func exitDeliversDrainedStderr() async throws {
        let box = ExitBox()
        // Retained for the duration, as every production caller does.
        let process = try ProcessRunner.stream(
            "/bin/sh", ["-c", "echo out; echo err >&2; exit 3"],
            onLines: { _ in },
            onExit: { box.set($0, $1) }
        )
        let result = try #require(try await awaitExit(box, upTo: 5))
        #expect(result.code == 3)
        #expect(result.stderr == "err")
        withExtendedLifetime(process) {}
    }

    /// Residual B: `sleep` inherits both pipe write-ends and outlives the
    /// shell, so EOF never arrives while it runs. Before the watchdog
    /// (`d854a40`) onExit never fired at all; now it must fire within ~2 s
    /// with the exit code intact.
    @Test func watchdogFiresWhenGrandchildHoldsPipes() async throws {
        let box = ExitBox()
        let process = try ProcessRunner.stream(
            "/bin/sh", ["-c", "sleep 10 & exit 7"],
            onLines: { _ in },
            onExit: { box.set($0, $1) }
        )
        let result = try #require(try await awaitExit(box, upTo: 8))
        #expect(result.code == 7)
        withExtendedLifetime(process) {}
    }

    /// The subtlety this suite originally caught: even if the caller drops
    /// the Process (releasing the pipes and handlers), the watchdog must
    /// keep itself alive long enough to fire.
    @Test func watchdogSurvivesCallerDroppingTheProcess() async throws {
        let box = ExitBox()
        _ = try ProcessRunner.stream(
            "/bin/sh", ["-c", "sleep 10 & exit 5"],
            onLines: { _ in },
            onExit: { box.set($0, $1) }
        )
        let result = try #require(try await awaitExit(box, upTo: 8))
        #expect(result.code == 5)
    }
}
