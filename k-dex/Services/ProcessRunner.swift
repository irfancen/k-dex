import Foundation

nonisolated struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

nonisolated enum ProcessError: Error, LocalizedError {
    case executableNotFound(String)
    case failed(command: String, exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "'\(name)' was not found. Install it or set its path in Settings."
        case .failed(let command, let exitCode, let stderr):
            let detail = stderr.isEmpty ? "exit code \(exitCode)" : stderr
            return "\(command): \(detail)"
        }
    }
}

nonisolated enum SettingsKeys {
    static let kubectlPath = "kubectlPath"
    static let kubeconfigPath = "kubeconfigPath"
    static let extraPath = "extraPATH"
    static let logTail = "logTail"
}

/// Tracks long-lived child processes (log follows, watches, port forwards)
/// so app termination can reap them even when their owners — view-scoped
/// streamers — are no longer reachable. Weak references: exited processes
/// fall out on their own.
nonisolated final class ProcessReaper: @unchecked Sendable {
    static let shared = ProcessReaper()

    private struct Entry { weak var process: Process? }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func register(_ process: Process) {
        lock.lock()
        entries.removeAll { $0.process == nil }
        entries.append(Entry(process: process))
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let processes = entries.compactMap(\.process)
        entries.removeAll()
        lock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
        }
    }
}

/// Runs external tools (kubectl, gunzip) with a PATH that covers the usual
/// install locations, since GUI apps don't inherit the user's shell PATH.
nonisolated enum ProcessRunner {
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// Once-only exit coordinator for streamed processes: `onExit` fires only
    /// after the process has exited AND both pipes have drained to EOF, so
    /// output callbacks are complete, in order, and stderr is never truncated.
    private final class StreamFinisher: @unchecked Sendable {
        private let lock = NSLock()
        private var exitCode: Int32?
        private var stdoutDone = false
        private var stderrDone = false
        private var fired = false
        private let errBox: OutputBox
        private let onExit: @Sendable (Int32, String) -> Void

        init(errBox: OutputBox, onExit: @escaping @Sendable (Int32, String) -> Void) {
            self.errBox = errBox
            self.onExit = onExit
        }

        func processExited(_ code: Int32) {
            lock.lock(); exitCode = code; lock.unlock()
            tryFire()
            // Watchdog: EOF requires every write-end to close, and a
            // grandchild that inherited the pipe (exec credential plugins can
            // outlive kubectl) may never close it — which would wedge onExit
            // forever, leaving a forward stuck in .starting or a log view
            // streaming. Fire with the stderr already buffered instead; no
            // pipe is read here, so drains can't race.
            // Strong self on purpose: the finisher is otherwise retained only
            // through the pipe handlers, and if the caller drops the Process
            // the whole chain deallocates and a weak watchdog would silently
            // never fire. Two seconds of extra lifetime is the entire cost.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                self.tryFire(force: true)
            }
        }

        func stdoutEOF() {
            lock.lock(); stdoutDone = true; lock.unlock()
            tryFire()
        }

        func stderrEOF() {
            lock.lock(); stderrDone = true; lock.unlock()
            tryFire()
        }

        private func tryFire(force: Bool = false) {
            lock.lock()
            guard !fired, let code = exitCode, force || (stdoutDone && stderrDone) else {
                lock.unlock()
                return
            }
            fired = true
            lock.unlock()
            let stderr = String(decoding: errBox.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onExit(code, stderr)
        }
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let defaults = UserDefaults.standard
        if let extra = defaults.string(forKey: SettingsKeys.extraPath), !extra.isEmpty {
            path = extra + ":" + path
        }
        let home = NSHomeDirectory()
        for candidate in ["/opt/homebrew/bin", "/usr/local/bin", home + "/bin", home + "/.local/bin", home + "/.krew/bin"]
        where !path.split(separator: ":").contains(Substring(candidate)) {
            path += ":" + candidate
        }
        env["PATH"] = path
        if let kubeconfig = defaults.string(forKey: SettingsKeys.kubeconfigPath), !kubeconfig.isEmpty {
            env["KUBECONFIG"] = (kubeconfig as NSString).expandingTildeInPath
        }
        return env
    }

    static func resolveExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        if name == "kubectl" {
            if let override = UserDefaults.standard.string(forKey: SettingsKeys.kubectlPath), !override.isEmpty {
                let path = (override as NSString).expandingTildeInPath
                if fm.isExecutableFile(atPath: path) { return path }
            }
            // Bundled copy: version-consistent and removes the
            // install-kubectl-first prerequisite. The Settings override above
            // still wins for users who want their own binary.
            let bundled = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/kubectl").path
            if fm.isExecutableFile(atPath: bundled) { return bundled }
        }
        if name.hasPrefix("/") {
            return fm.isExecutableFile(atPath: name) ? name : nil
        }
        for dir in (environment()["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs a command to completion, returning its output regardless of exit code.
    static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil) async throws -> ProcessResult {
        guard let path = resolveExecutable(executable) else {
            throw ProcessError.executableNotFound(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let inPipe {
                    let input = stdin ?? Data()
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: input)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }

                // Drain both pipes concurrently so a full stderr buffer can't
                // deadlock a process still writing to stdout (or vice versa).
                let outBox = OutputBox()
                let errBox = OutputBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    if let data = try? outPipe.fileHandleForReading.readToEnd() { outBox.append(data) }
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    if let data = try? errPipe.fileHandleForReading.readToEnd() { errBox.append(data) }
                    group.leave()
                }
                group.notify(queue: .global(qos: .userInitiated)) {
                    process.waitUntilExit()
                    continuation.resume(returning: ProcessResult(
                        stdout: outBox.data,
                        stderr: errBox.data,
                        exitCode: process.terminationStatus
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs a command and throws if it exits non-zero. kubectl warnings on
    /// stderr are dropped from the error message so the real failure shows.
    @discardableResult
    static func runChecked(_ executable: String, _ arguments: [String], stdin: Data? = nil) async throws -> ProcessResult {
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
                stderr: errors.isEmpty ? stderr : errors
            )
        }
        return result
    }

    /// Launches a long-running command, delivering stdout line batches as they
    /// arrive. Returns the Process so the caller can terminate it.
    static func stream(
        _ executable: String,
        _ arguments: [String],
        onLines: @escaping @Sendable ([String]) -> Void,
        onExit: @escaping @Sendable (Int32, String) -> Void
    ) throws -> Process {
        guard let path = resolveExecutable(executable) else {
            throw ProcessError.executableNotFound(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let lineBuffer = LineBuffer()
        let errBox = OutputBox()
        let finisher = StreamFinisher(errBox: errBox, onExit: onExit)

        // Teardown is driven by each pipe's own EOF (delivered on the
        // handler's queue, in order after all data), never by racing a
        // readToEnd against a handler on another queue.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let tail = lineBuffer.flushRemainder() { onLines([tail]) }
                finisher.stdoutEOF()
                return
            }
            let lines = lineBuffer.appendAndExtractLines(data)
            if !lines.isEmpty { onLines(lines) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finisher.stderrEOF()
                return
            }
            errBox.append(data)
        }

        process.terminationHandler = { finished in
            finisher.processExited(finished.terminationStatus)
        }

        try process.run()
        ProcessReaper.shared.register(process)
        return process
    }

    /// Launches a long-running command, delivering raw stdout chunks as they
    /// arrive — for output that isn't line-oriented, like the concatenated
    /// pretty-printed JSON documents of `kubectl get --watch -o json`.
    static func streamData(
        _ executable: String,
        _ arguments: [String],
        onData: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32, String) -> Void
    ) throws -> Process {
        guard let path = resolveExecutable(executable) else {
            throw ProcessError.executableNotFound(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let errBox = OutputBox()
        let finisher = StreamFinisher(errBox: errBox, onExit: onExit)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finisher.stdoutEOF()
                return
            }
            onData(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finisher.stderrEOF()
                return
            }
            errBox.append(data)
        }

        process.terminationHandler = { finished in
            finisher.processExited(finished.terminationStatus)
        }

        try process.run()
        ProcessReaper.shared.register(process)
        return process
    }

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func appendAndExtractLines(_ data: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            var lines: [String] = []
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                lines.append(String(decoding: lineData, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
            }
            return lines
        }

        func flushRemainder() -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard !buffer.isEmpty else { return nil }
            let text = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            return text
        }
    }
}
