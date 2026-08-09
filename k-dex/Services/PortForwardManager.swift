import Foundation
import Observation

/// Owns all active `kubectl port-forward` subprocesses.
@MainActor
@Observable
final class PortForwardManager {
    enum ForwardState: Equatable {
        case starting
        case active
        case failed(String)
    }

    struct Forward: Identifiable {
        let id = UUID()
        let context: String
        let namespace: String
        /// kubectl target token: "pod", "service", or a workload kind
        /// ("deployment", "statefulset", …) that kubectl resolves to a pod.
        let targetType: String
        let targetName: String
        let localPort: Int
        let remotePort: Int
        var state: ForwardState = .starting

        var displayTarget: String { "\(targetType)/\(targetName)" }
        var localURL: URL? { URL(string: "http://localhost:\(localPort)") }
    }

    private(set) var forwards: [Forward] = []
    @ObservationIgnored private var processes: [UUID: Process] = [:]
    /// Forwards the user asked to stop: their exit is expected, so the row is
    /// removed instead of surfacing SIGTERM noise as a failure.
    @ObservationIgnored private var stopping: Set<UUID> = []

    func start(context: String, namespace: String, targetType: String, targetName: String, localPort: Int, remotePort: Int) {
        let forward = Forward(
            context: context,
            namespace: namespace,
            targetType: targetType,
            targetName: targetName,
            localPort: localPort,
            remotePort: remotePort
        )
        forwards.append(forward)
        let id = forward.id

        let args = [
            "port-forward",
            "\(targetType)/\(targetName)",
            "\(localPort):\(remotePort)",
            "-n", namespace,
            "--context", context,
        ]
        do {
            let process = try ProcessRunner.stream(
                "kubectl", args,
                onLines: { [weak self] batch in
                    guard batch.contains(where: { $0.contains("Forwarding from") }) else { return }
                    Task { @MainActor in self?.update(id: id, state: .active) }
                },
                onExit: { [weak self] code, stderr in
                    Task { @MainActor in
                        guard let self else { return }
                        self.processes[id] = nil
                        let wasStopping = self.stopping.remove(id) != nil
                        guard let index = self.forwards.firstIndex(where: { $0.id == id }) else { return }
                        if wasStopping {
                            self.forwards.remove(at: index)
                        } else if code != 0 {
                            self.forwards[index].state = .failed(
                                stderr.isEmpty ? "kubectl port-forward exited (code \(code))" : stderr
                            )
                        } else {
                            self.forwards.remove(at: index)
                        }
                    }
                }
            )
            processes[id] = process
        } catch {
            update(id: id, state: .failed(error.localizedDescription))
        }
    }

    func stop(id: UUID) {
        if let process = processes[id], process.isRunning {
            stopping.insert(id)
            process.terminate() // removal happens in onExit
        } else {
            forwards.removeAll { $0.id == id }
            processes[id] = nil
        }
    }

    func stopAll() {
        // Every one of these exits is user-requested: mark them so onExit
        // removes the rows instead of reporting SIGTERM as a failure. Rows
        // without a live process (already failed) are cleared immediately.
        for (id, process) in processes where process.isRunning {
            stopping.insert(id)
            process.terminate()
        }
        forwards.removeAll { processes[$0.id]?.isRunning != true }
    }

    private func update(id: UUID, state: ForwardState) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        forwards[index].state = state
    }
}
