import Foundation

/// UserDefaults persistence for the app's own cluster state.
///
/// The kubeconfig's `current-context` says what the next bare `kubectl` call
/// would talk to. It is not what this app was last looking at, and the app
/// deliberately never writes it (every subprocess carries `--context`), so a
/// session spent in a second cluster left no trace: the picker kept badging
/// the local cluster and the namespace choice was rediscovered every launch.
/// This is the state that was missing.
nonisolated enum ClusterStateStore {
    /// A stored namespace choice. "Never visited" and "explicitly all
    /// namespaces" are different answers — the first lets the kubeconfig's own
    /// default namespace speak, the second is the user overriding it.
    enum StoredNamespace: Equatable {
        case unset
        case all
        case named(String)

        var name: String? {
            if case .named(let name) = self { return name }
            return nil
        }
    }

    private static let lastContextKey = "cluster-last-context"

    private static func namespaceKey(_ context: String) -> String {
        "cluster-namespace-\(context)"
    }

    static var lastContext: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: lastContextKey) ?? ""
            return stored.isEmpty ? nil : stored
        }
        set {
            UserDefaults.standard.set(newValue ?? "", forKey: lastContextKey)
        }
    }

    static func namespace(for context: String) -> StoredNamespace {
        guard !context.isEmpty,
              let stored = UserDefaults.standard.string(forKey: namespaceKey(context)) else { return .unset }
        return stored.isEmpty ? .all : .named(stored)
    }

    static func store(namespace: String?, for context: String) {
        guard !context.isEmpty else { return }
        UserDefaults.standard.set(namespace ?? "", forKey: namespaceKey(context))
    }
}
