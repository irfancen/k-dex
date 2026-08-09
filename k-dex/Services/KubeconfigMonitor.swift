import Foundation

/// Locates the kubeconfig the spawned kubectl will read, for file watching.
/// Resolution mirrors ProcessRunner's env construction: the in-app settings
/// override wins, then the inherited KUBECONFIG (first entry), then the
/// default `~/.kube/config`.
enum KubeconfigLocation {
    static var path: String {
        if let override = UserDefaults.standard.string(forKey: SettingsKeys.kubeconfigPath), !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        if let env = ProcessInfo.processInfo.environment["KUBECONFIG"],
           let first = env.split(separator: ":").first, !first.isEmpty {
            return (String(first) as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/.kube/config"
    }
}

/// Fires a callback when one file changes — including the atomic
/// write-temp-then-rename replace kubectl and most editors perform, where the
/// watched inode vanishes and the source must be re-armed on the new one.
/// While the file is absent (deleted, not yet recreated) it retries once a
/// second, which is a bare `open(2)` — not the subprocess a poll would cost.
final class FileChangeMonitor {
    private let path: String
    private let onChange: @MainActor () -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var retryTask: Task<Void, Never>?

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() { arm() }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        source?.cancel()
        source = nil
    }

    private func arm() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRearm()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let events = source.data
            Task { @MainActor in
                guard let self else { return }
                self.onChange()
                if events.contains(.delete) || events.contains(.rename) {
                    // Atomic replace: this inode is gone; watch the new one.
                    self.source?.cancel()
                    self.source = nil
                    self.arm()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func scheduleRearm() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.arm()
        }
    }
}
