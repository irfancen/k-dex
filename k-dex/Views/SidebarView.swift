import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    /// Comma-separated ids of collapsed sidebar sections.
    @AppStorage("sidebar-collapsed") private var collapsedSections = ""
    /// Bumped after a drag-reorder so the list re-reads the stored order.
    @State private var orderVersion = 0

    var body: some View {
        @Bindable var model = model
        let _ = orderVersion
        List(selection: $model.sidebarSelection) {
            Section {
                contextSwitcher
            }

            Section {
                Label("Overview", systemImage: "rectangle.3.group")
                    .tag(SidebarItem.overview)
            }

            Section {
                ForEach(sectionTokens, id: \.self) { token in
                    sectionGroup(token)
                }
                .onMove { source, destination in
                    var tokens = sectionTokens
                    tokens.move(fromOffsets: source, toOffset: destination)
                    saveSectionOrder(tokens)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                model.showKindSearch = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Go to Resource")
                    Spacer()
                    Text("⌘K")
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            // Opaque backing: the list scrolls underneath the inset.
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .help("Jump to any resource kind, including hidden ones and CRDs (⌘K)")
        }
    }

    // MARK: Reorderable sections

    private static let sectionOrderKey = "sidebar-section-order-v3"

    /// One section token per CRD API group ("crd:cert-manager.io"), so each
    /// installed operator gets its own sidebar section, Aptakube-style.
    private var crdGroupTokens: [String] {
        Set(model.kindCatalog.filter(\.isCustom).map(\.group))
            .sorted()
            .map { "crd:\($0)" }
    }

    /// Cluster first by default (Aptakube-style), then helm and the rest;
    /// CRD group sections slot in before Other.
    private var defaultSectionOrder: [String] {
        ["cluster", "helm", "workloads", "network", "config", "storage", "access"]
            + crdGroupTokens + ["other"]
    }

    /// Section tokens (category raw values, "helm", "crd:<group>") in the
    /// user's order. Tokens for uninstalled CRD groups prune automatically.
    private var sectionTokens: [String] {
        let defaults = defaultSectionOrder
        guard let csv = UserDefaults.standard.string(forKey: Self.sectionOrderKey), !csv.isEmpty else {
            return defaults
        }
        let stored = csv.split(separator: ",").map(String.init).filter { defaults.contains($0) }
        return stored + defaults.filter { !stored.contains($0) }
    }

    private func sectionTitle(for token: String) -> String {
        if token.hasPrefix("crd:") { return String(token.dropFirst(4)) }
        return ResourceCategory(rawValue: token)?.title ?? token
    }

    /// The kinds a section token owns (unordered, hidden ones included).
    private func kinds(forToken token: String) -> [ResourceKind] {
        if token.hasPrefix("crd:") {
            let group = String(token.dropFirst(4))
            return model.kindCatalog.filter { $0.isCustom && $0.group == group }
        }
        guard let category = ResourceCategory(rawValue: token), category != .crd else { return [] }
        return model.kinds(in: category)
    }

    /// A draggable, collapsible category group. Rendered as an outline row
    /// (not a section header) because macOS lists only support dragging rows.
    @ViewBuilder
    private func sectionGroup(_ token: String) -> some View {
        if token == "helm" {
            DisclosureGroup(isExpanded: expandedBinding("helm")) {
                itemLabel("Releases", icon: "shippingbox")
                    .tag(SidebarItem.helm)
            } label: {
                groupLabel("Helm", token: token)
            }
        } else {
            // Sections render only when the catalog has kinds for them.
            if !orderedKinds(forToken: token).isEmpty {
                DisclosureGroup(isExpanded: expandedBinding(token)) {
                    ForEach(visibleKinds(forToken: token)) { kind in
                        itemLabel(kind.displayName, icon: kind.icon)
                            .tag(SidebarItem.resource(kind))
                            .help(kind.cliName)
                            .contextMenu {
                                Button("Hide \(kind.displayName)") { toggleKindVisibility(kind) }
                            }
                    }
                    .onMove { source, destination in
                        moveKinds(token: token, from: source, to: destination)
                    }
                } label: {
                    groupLabel(sectionTitle(for: token), token: token)
                }
            }
        }
    }

    /// Explicit text color in dark mode: drag previews lose the dark
    /// appearance and would otherwise render dynamic label colors as black.
    private func itemLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(colorScheme == .dark ? AnyShapeStyle(Color(white: 0.92)) : AnyShapeStyle(.primary))
            .padding(.leading, -14) // counter the outline indentation
    }

    /// No gestures here: any SwiftUI gesture on the row blocks AppKit row
    /// dragging. Click-to-toggle works via row selection instead (the row is
    /// tagged `.category`, and RootView bounces that selection into a toggle).
    private func groupLabel(_ title: String, token: String) -> some View {
        let tokens = sectionTokens
        let index = tokens.firstIndex(of: token) ?? 0
        return Text(title)
            .font(.callout.weight(.semibold))
            // Explicit color: dynamic .secondary resolves as light-mode black
            // in drag previews, which lose the dark appearance context.
            .foregroundStyle(colorScheme == .dark ? Color(white: 0.72) : Color(white: 0.35))
            .padding(.leading, 4)
            .tag(SidebarItem.category(token))
            .contextMenu {
                Button("Move Up") { moveSection(token, offset: -1) }
                    .disabled(index == 0)
                Button("Move Down") { moveSection(token, offset: 1) }
                    .disabled(index == tokens.count - 1)
                let kinds = menuKinds(for: token)
                if !kinds.isEmpty {
                    Divider()
                    Menu("Visible Items") {
                        ForEach(kinds) { kind in
                            Toggle(kind.displayName, isOn: visibilityBinding(kind))
                        }
                    }
                }
            }
    }

    // MARK: Per-item visibility

    private func visibleKinds(forToken token: String) -> [ResourceKind] {
        orderedKinds(forToken: token).filter { KindVisibilityStore.isVisible($0) }
    }

    /// All kinds a section's "Visible Items" menu offers, hidden ones included.
    private func menuKinds(for token: String) -> [ResourceKind] {
        orderedKinds(forToken: token)
    }

    private func visibilityBinding(_ kind: ResourceKind) -> Binding<Bool> {
        Binding(
            get: { KindVisibilityStore.isVisible(kind) },
            set: { _ in toggleKindVisibility(kind) }
        )
    }

    private func toggleKindVisibility(_ kind: ResourceKind) {
        KindVisibilityStore.toggle(kind)
        if !KindVisibilityStore.isVisible(kind), model.sidebarSelection == .resource(kind) {
            model.sidebarSelection = .overview
        }
        orderVersion += 1
    }

    private func saveSectionOrder(_ tokens: [String]) {
        UserDefaults.standard.set(tokens.joined(separator: ","), forKey: Self.sectionOrderKey)
        orderVersion += 1
    }

    private func moveSection(_ token: String, offset: Int) {
        var tokens = sectionTokens
        guard let index = tokens.firstIndex(of: token) else { return }
        let target = index + offset
        guard tokens.indices.contains(target) else { return }
        tokens.swapAt(index, target)
        saveSectionOrder(tokens)
    }

    // MARK: Reorderable items

    private func orderKey(_ token: String) -> String {
        "sidebar-order-\(token)"
    }

    /// Kinds of a section in the user's stored order; new kinds append at the end.
    private func orderedKinds(forToken token: String) -> [ResourceKind] {
        let defaults = kinds(forToken: token)
        guard let csv = UserDefaults.standard.string(forKey: orderKey(token)), !csv.isEmpty else {
            return defaults
        }
        let stored = csv.split(separator: ",")
            .compactMap { id in defaults.first { $0.id == id } }
        return stored + defaults.filter { !stored.contains($0) }
    }

    private func moveKinds(token: String, from source: IndexSet, to destination: Int) {
        // Drag indices refer to the *visible* rows; hidden kinds tag along at
        // the end so they reappear in a sane spot when re-enabled.
        var visible = visibleKinds(forToken: token)
        let hidden = orderedKinds(forToken: token).filter { !KindVisibilityStore.isVisible($0) }
        visible.move(fromOffsets: source, toOffset: destination)
        UserDefaults.standard.set(
            (visible + hidden).map(\.id).joined(separator: ","),
            forKey: orderKey(token)
        )
        orderVersion += 1
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.split(separator: ",").map(String.init).contains(id) },
            set: { expanded in
                var collapsed = Set(collapsedSections.split(separator: ",").map(String.init))
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
                collapsedSections = collapsed.sorted().joined(separator: ",")
            }
        )
    }

    private var contextSwitcher: some View {
        Menu {
            ForEach(model.contexts) { context in
                Button {
                    model.switchContext(context.name)
                } label: {
                    if context.name == model.selectedContext {
                        Label(context.name, systemImage: "checkmark")
                    } else {
                        Text(context.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selectedContext.isEmpty ? "No context" : model.selectedContext)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let cluster = currentCluster, cluster != model.selectedContext {
                        Text(cluster)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch cluster context")
    }

    private var currentCluster: String? {
        model.contexts.first { $0.name == model.selectedContext }?.cluster
    }
}

/// Per-item sidebar visibility. Each kind's default comes from its enrichment
/// (niche and non-curated kinds ship hidden); user choices are stored as
/// overrides (hidden vs. explicitly-shown) so the defaults can evolve without
/// clobbering them. Hidden kinds stay reachable via ⌘K search.
nonisolated enum KindVisibilityStore {
    private static let hiddenKey = "sidebar-hidden-kinds"
    private static let shownKey = "sidebar-shown-kinds"

    static func isVisible(_ kind: ResourceKind) -> Bool {
        if kind.visibleByDefault { return !ids(forKey: hiddenKey).contains(kind.id) }
        return ids(forKey: shownKey).contains(kind.id)
    }

    static func toggle(_ kind: ResourceKind) {
        let key = kind.visibleByDefault ? hiddenKey : shownKey
        var set = ids(forKey: key)
        if set.contains(kind.id) { set.remove(kind.id) } else { set.insert(kind.id) }
        UserDefaults.standard.set(set.sorted().joined(separator: ","), forKey: key)
    }

    private static func ids(forKey key: String) -> Set<String> {
        Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init))
    }
}

/// Sidebar section collapse state, shared so RootView can toggle it when a
/// category row is clicked (selected).
nonisolated enum SidebarSectionStore {
    static func toggle(_ id: String) {
        let key = "sidebar-collapsed"
        var collapsed = Set(
            (UserDefaults.standard.string(forKey: key) ?? "")
                .split(separator: ",")
                .map(String.init)
        )
        if collapsed.contains(id) {
            collapsed.remove(id)
        } else {
            collapsed.insert(id)
        }
        UserDefaults.standard.set(collapsed.sorted().joined(separator: ","), forKey: key)
    }
}
