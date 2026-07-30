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
            if let warning = model.kubectlVersionWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") { model.kubectlVersionWarning = nil }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
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
