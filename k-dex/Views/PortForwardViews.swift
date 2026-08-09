import SwiftUI
import AppKit

/// Toolbar button showing active forwards, with a management popover.
struct PortForwardsButton: View {
    @Environment(PortForwardManager.self) private var manager
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Label("Port Forwards", systemImage: "rectangle.connected.to.line.below")
                .overlay(alignment: .topTrailing) {
                    if !manager.forwards.isEmpty {
                        Text(String(manager.forwards.count))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.blue, in: Circle())
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .help("Active port forwards")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            PortForwardListView()
                .frame(width: 380)
        }
    }
}

struct PortForwardListView: View {
    @Environment(PortForwardManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Port Forwards")
                .font(.headline)

            if manager.forwards.isEmpty {
                Text("No active forwards. Right-click a pod, service, or workload and choose “Port Forward…”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.forwards) { forward in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(stateColor(forward.state))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(forward.displayTarget)
                                .font(.callout)
                                .lineLimit(1)
                            // String(port): LocalizedStringKey interpolation
                            // would localize Ints as quantities ("5.173" for
                            // port 5173 under a dot-grouping locale).
                            Text("localhost:\(String(forward.localPort)) → \(String(forward.remotePort)) · \(forward.namespace)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if case .failed(let message) = forward.state {
                                Text(message)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if forward.state == .active, let url = forward.localURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "safari")
                            }
                            .buttonStyle(.borderless)
                            .help("Open in browser")
                        }
                        Button {
                            manager.stop(id: forward.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop forwarding")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
    }

    private func stateColor(_ state: PortForwardManager.ForwardState) -> Color {
        switch state {
        case .starting: return .orange
        case .active: return .green
        case .failed: return .red
        }
    }
}

struct PortForwardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(PortForwardManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    let object: KubeObject
    let kind: ResourceKind

    @State private var remotePort: Int
    @State private var localPort: Int

    private let suggestedPorts: [Int]

    init(object: KubeObject, kind: ResourceKind) {
        self.object = object
        self.kind = kind
        // Suggested remote ports, by target shape: a Service forwards one of
        // its service ports; a Pod exposes its containers' ports; workloads
        // (kubectl resolves them to one of their pods) declare theirs on the
        // pod template.
        let ports: [Int]
        if kind == .services {
            ports = object.raw["spec"]["ports"].array.compactMap { $0["port"].int }
        } else {
            let spec = kind == .pods ? object.raw["spec"] : object.raw["spec"]["template"]["spec"]
            ports = spec["containers"].array
                .flatMap { $0["ports"].array }
                .compactMap { $0["containerPort"].int }
        }
        self.suggestedPorts = Array(Set(ports)).sorted()
        let initial = ports.first ?? 80
        _remotePort = State(initialValue: initial)
        _localPort = State(initialValue: initial < 1024 ? initial + 8000 : initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Port Forward")
                .font(.headline)
            LabeledContent("Target", value: "\(targetType)/\(object.name)")

            if suggestedPorts.isEmpty {
                LabeledContent("Remote port") {
                    TextField("Remote", value: $remotePort, format: .number.grouping(.never))
                        .frame(width: 80)
                }
            } else {
                LabeledContent("Remote port") {
                    Picker("Remote port", selection: $remotePort) {
                        ForEach(suggestedPorts, id: \.self) { port in
                            Text(String(port)).tag(port)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }

            LabeledContent("Local port") {
                TextField("Local", value: $localPort, format: .number.grouping(.never))
                    .frame(width: 80)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start") {
                    manager.start(
                        context: model.selectedContext,
                        namespace: object.namespace,
                        targetType: targetType,
                        targetName: object.name,
                        localPort: localPort,
                        remotePort: remotePort
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(localPort <= 0 || remotePort <= 0)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    /// The kubectl target token ("deployment", "service", …). kubectl
    /// resolves singular kind names for every built-in that can forward.
    private var targetType: String {
        kind.kindName.lowercased()
    }
}
