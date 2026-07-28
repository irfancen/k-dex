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
        if name == "kubectl",
           let override = UserDefaults.standard.string(forKey: SettingsKeys.kubectlPath), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return path }
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

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let lines = lineBuffer.appendAndExtractLines(data)
            if !lines.isEmpty { onLines(lines) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errBox.append(data)
        }

        process.terminationHandler = { finished in
            // Give the readability handlers a moment to drain, then flush the tail.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    let lines = lineBuffer.appendAndExtractLines(rest)
                    if !lines.isEmpty { onLines(lines) }
                }
                if let tail = lineBuffer.flushRemainder() { onLines([tail]) }
                let stderrText = String(decoding: errBox.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                onExit(finished.terminationStatus, stderrText)
            }
        }

        try process.run()
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

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            onData(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errBox.append(data)
        }

        process.terminationHandler = { finished in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    onData(rest)
                }
                let stderrText = String(decoding: errBox.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                onExit(finished.terminationStatus, stderrText)
            }
        }

        try process.run()
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
