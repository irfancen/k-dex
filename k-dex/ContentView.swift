import SwiftUI
import AppKit
import Combine

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(PortForwardManager.self) private var portForwards
    @State private var suppressSelectionChange = false

    var body: some View {
        Group {
            switch model.bootState {
            case .loading:
                ProgressView("Connecting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missingKubectl, .noContexts, .failed:
                WelcomeView()
            case .pickCluster:
                ClusterPickerView()
            case .ready:
                mainSplit
            }
        }
        .task { await model.bootstrap() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            portForwards.stopAll() // don't leave kubectl port-forward orphans behind
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.isAppActive = false
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // The mirror is stale and the app could not ask for the grant
                // itself, because the re-sync runs unattended. Dismissing is
                // not offered: every command keeps failing until it is fixed,
                // so the only useful button is the one that fixes it.
                if let warning = model.mirrorWarning {
                    WarningBar(message: warning, icon: "lock.trianglebadge.exclamationmark.fill") {
                        Button("Grant Access…") {
                            Task { await model.resolveMirrorWarning() }
                        }
                        .controlSize(.small)
                    }
                }
                if let warning = model.kubectlVersionWarning {
                    WarningBar(message: warning, icon: "exclamationmark.triangle.fill") {
                        Button("Dismiss") { model.kubectlVersionWarning = nil }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var mainSplit: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            switch model.sidebarSelection {
            case .overview:
                OverviewView()
            case .resource(let kind):
                ResourceListView(kind: kind)
                    .id(kind) // reset table/scroll state when switching kinds
            case .helm:
                HelmListView()
            case .category, nil:
                Text("Select a resource")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.sidebarSelection) { oldValue, newValue in
            if suppressSelectionChange {
                suppressSelectionChange = false
                return
            }
            // Clicking a category row means "toggle that section", not "navigate".
            if case .category(let token) = newValue {
                SidebarSectionStore.toggle(token)
                suppressSelectionChange = true
                model.sidebarSelection = oldValue
                return
            }
            model.sidebarSelectionChanged()
        }
        .overlay {
            if model.showKindSearch {
                KindSearchOverlay()
            }
        }
        .background(ToolbarConfigurator())
    }
}

/// Disables the native toolbar right-click customization menu
/// ("Icon and Text / Icon Only / Text Only").
private struct ToolbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let toolbar = window?.toolbar else { return }
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
    }
}

/// One line of trouble at the bottom of the window, with the action that
/// addresses it. Shared so a second warning cannot drift from the first.
private struct WarningBar<Action: View>: View {
    let message: String
    let icon: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
