import SwiftUI

/// Launch screen: every kubeconfig context as a card; picking one connects
/// and enters the cluster. Reachable again via "All Clusters…" in the
/// sidebar's context switcher.
struct ClusterPickerView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private var filtered: [KubeContext] {
        guard !query.isEmpty else { return ordered }
        let q = query.lowercased()
        return ordered.filter {
            $0.name.lowercased().contains(q) || $0.cluster.lowercased().contains(q)
        }
    }

    /// The remembered cluster, but only while the kubeconfig still lists it:
    /// deleting a context, or pointing Settings at a different kubeconfig,
    /// leaves the memory dangling and the picker must not act on it.
    private var remembered: String? {
        guard let last = model.lastUsedContext,
              model.contexts.contains(where: { $0.name == last }) else { return nil }
        return last
    }

    /// The cluster this app was last in leads, whatever the kubeconfig lists
    /// first; the rest keep kubeconfig order.
    private var ordered: [KubeContext] {
        guard let remembered,
              let index = model.contexts.firstIndex(where: { $0.name == remembered }) else { return model.contexts }
        var contexts = model.contexts
        contexts.insert(contexts.remove(at: index), at: 0)
        return contexts
    }

    /// App state wins: the cluster you last worked in is the one marked. Only
    /// before the app has been used anywhere does the kubeconfig's
    /// `current-context` get the badge — otherwise the picker would keep
    /// pointing at the local cluster after a week in a remote one.
    private func badge(for context: KubeContext) -> String? {
        if let remembered {
            return context.name == remembered ? "last used" : nil
        }
        return context.name == model.kubeconfigCurrentContext ? "current" : nil
    }

    /// The namespace the card promises to open in — the app's memory of this
    /// cluster first, the kubeconfig's default namespace only where it has none.
    private func namespaceLabel(for context: KubeContext) -> String? {
        switch model.storedNamespace(for: context.name) {
        case .named(let namespace): return "ns: \(namespace)"
        case .all: return "all namespaces"
        case .unset:
            guard let namespace = context.defaultNamespace, !namespace.isEmpty else { return nil }
            return "ns: \(namespace)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "helm")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Select a Cluster")
                    .font(.title2.weight(.semibold))
                Text("\(model.contexts.count) context\(model.contexts.count == 1 ? "" : "s") in your kubeconfig")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 44)
            .padding(.bottom, 18)

            // Also shown while a query is active: a reload can drop the
            // context count below the threshold, and hiding the field then
            // would leave the list filtered with no way to clear it.
            if model.contexts.count > 6 || !query.isEmpty {
                TextField("Filter clusters…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .padding(.bottom, 12)
            }

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 10
                ) {
                    ForEach(filtered) { context in
                        ClusterCard(
                            context: context,
                            badge: badge(for: context),
                            namespaceLabel: namespaceLabel(for: context)
                        ) {
                            model.connect(to: context.name)
                        }
                    }
                }
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
                .padding(.bottom, 20)
                if filtered.isEmpty {
                    Text("No matching clusters")
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
            }

            Divider()
            HStack {
                // ⌘R reaches here through the menu-bar Refresh command,
                // which dispatches on bootState — a second binding here
                // would collide with it.
                Button("Reload") { Task { await model.reloadContexts() } }
                    .help("Re-read the kubeconfig (⌘R)")
                Spacer()
                SettingsLink { Text("Settings…") }
                    .help("Change the kubeconfig or kubectl path")
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Kubeconfig edits (new clusters, removed ones) show up on their own
        // while the picker is visible: a file watch, not subprocess polling —
        // immediate on change, idle otherwise. Torn down on disappear.
        .task {
            let monitor = FileChangeMonitor(path: KubeconfigLocation.path) {
                Task { await model.reloadContexts() }
            }
            monitor.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
            monitor.stop()
        }
    }
}

private struct ClusterCard: View {
    let context: KubeContext
    /// "last used" (app state) or "current" (kubeconfig, first run only).
    let badge: String?
    let namespaceLabel: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 17))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(context.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.tint.opacity(0.15)))
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.04))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        var parts = [context.cluster]
        if context.user != context.name { parts.append(context.user) }
        if let namespaceLabel { parts.append(namespaceLabel) }
        return parts.joined(separator: " · ")
    }
}
