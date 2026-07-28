import Foundation
import Observation

/// Streams `kubectl logs` for one container, keeping a bounded line buffer.
@MainActor
@Observable
final class LogStreamer {
    struct Line: Identifiable, Sendable {
        let id: Int
        let text: String
    }

    private(set) var lines: [Line] = []
    private(set) var isStreaming = false
    private(set) var statusMessage: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var nextID = 0
    /// Monotonic launch token: callbacks from a superseded process (its
    /// delayed onExit after a restart) are ignored instead of clobbering the
    /// live stream's state.
    @ObservationIgnored private var runToken = 0

    private static let maxLines = 6000

    enum Target {
        case pod(name: String, container: String?)
        /// All pods matching a label selector, with pod-name prefixes;
        /// optionally narrowed to one container of each pod.
        case selector(String, container: String?)
    }

    func start(
        context: String,
        namespace: String,
        target: Target,
        follow: Bool,
        tail: Int,
        timestamps: Bool,
        previous: Bool = false
    ) {
        stop()
        lines = []
        statusMessage = nil

        var args = ["logs"]
        switch target {
        case .pod(let name, let container):
            args.append(name)
            if let container, !container.isEmpty {
                args += ["-c", container]
            } else {
                // "All Containers" on a multi-container pod; prefix lines so
                // the streams stay distinguishable.
                args += ["--all-containers=true", "--prefix"]
            }
        case .selector(let selector, let container):
            args += ["-l", selector, "--prefix", "--max-log-requests", "20"]
            if let container, !container.isEmpty {
                args += ["-c", container]
            } else {
                args.append("--all-containers=true")
            }
        }
        args += ["-n", namespace, "--context", context, "--tail", String(tail)]
        if timestamps { args.append("--timestamps") }
        if previous {
            // The crashed (previous) container instance; static, so no follow.
            args.append("--previous")
        } else if follow {
            args.append("--follow")
        }

        let token = runToken
        do {
            process = try ProcessRunner.stream(
                "kubectl", args,
                onLines: { [weak self] batch in
                    Task { @MainActor in
                        guard let self, self.runToken == token else { return }
                        self.append(batch)
                    }
                },
                onExit: { [weak self] code, stderr in
                    Task { @MainActor in
                        guard let self, self.runToken == token else { return }
                        self.finished(code: code, stderr: stderr)
                    }
                }
            )
            isStreaming = true
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func stop() {
        runToken &+= 1
        if let process, process.isRunning { process.terminate() }
        process = nil
        isStreaming = false
    }

    func clear() {
        lines = []
    }

    private func append(_ batch: [String]) {
        var id = nextID
        lines.append(contentsOf: batch.map { text in
            defer { id += 1 }
            return Line(id: id, text: text)
        })
        nextID = id
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines + 1000)
        }
    }

    private func finished(code: Int32, stderr: String) {
        isStreaming = false
        process = nil
        if code != 0, !stderr.isEmpty {
            statusMessage = stderr
        } else if code == 0 {
            statusMessage = "Log stream ended."
        }
    }
}
