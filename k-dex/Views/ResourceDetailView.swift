import SwiftUI

struct ResourceDetailView: View {
    @Environment(AppModel.self) private var model
    let object: KubeObject
    let kind: ResourceKind
    var onDelete: (() -> Void)?
    var onScale: (() -> Void)?
    var onForward: (() -> Void)?
    var onRestart: (() -> Void)?

    private enum Tab: String, CaseIterable {
        case overview = "Overview"
        case pods = "Pods"
        case yaml = "YAML"
        case logs = "Logs"
        case events = "Events"
    }

    @State private var tab: Tab = .overview

    private var tabs: [Tab] {
        var tabs: [Tab] = [.overview]
        if kind.showsPods || kind == .nodes { tabs.append(.pods) }
        tabs.append(.yaml)
        if kind.supportsLogs || kind.showsPods { tabs.append(.logs) }
        tabs.append(.events)
        return tabs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Picker("Tab", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch tab {
                case .overview:
                    OverviewTab(object: object, kind: kind)
                case .pods:
                    WorkloadPodsTab(object: object, kind: kind)
                case .yaml:
                    YAMLTab(object: object, kind: kind)
                case .logs:
                    LogView(object: object, kind: kind)
                case .events:
                    EventsTab(object: object, kind: kind)
                }
            }
            // Per-object identity: without this, selecting another row keeps
            // the previous object's tab @State alive — an in-progress YAML
            // draft would apply to the wrong object, revealed Secret keys
            // leak across selections, and the log container picker keeps the
            // previous pod's container.
            .id(object.id)
        }
        .padding(.leading, 8) // grab gutter: keeps the resize cursor usable next to text views
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { consumePendingTab() }
        .onChange(of: model.pendingDetailTab) { consumePendingTab() }
        .onChange(of: object.id) {
            if !tabs.contains(tab) { tab = .overview }
            consumePendingTab()
        }
    }

    /// Context-menu actions like "Logs"/"YAML" request a specific tab.
    private func consumePendingTab() {
        guard let pending = model.pendingDetailTab else { return }
        model.pendingDetailTab = nil
        switch pending {
        case "logs" where tabs.contains(.logs): tab = .logs
        case "pods" where tabs.contains(.pods): tab = .pods
        case "yaml": tab = .yaml
        case "events": tab = .events
        default: break
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    model.selectedObjectID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if onDelete != nil || onScale != nil || onForward != nil || onRestart != nil {
                    Menu {
                        if let onForward {
                            Button("Port Forward…", action: onForward)
                        }
                        if let onScale {
                            Button("Scale…", action: onScale)
                        }
                        if let onRestart {
                            Button("Rollout Restart…", action: onRestart)
                        }
                        if let onDelete {
                            Divider()
                            Button("Delete…", role: .destructive, action: onDelete)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            Text(object.name)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var headerSubtitle: String {
        var parts = [kind.kindName]
        if !object.namespace.isEmpty { parts.append(object.namespace) }
        parts.append(Fmt.age(object.creationDate))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Overview

private struct OverviewTab: View {
    @Environment(AppModel.self) private var model
    let object: KubeObject
    let kind: ResourceKind

    var body: some View {
        let rowContext = model.rowContext
        Form {
            Section("Metadata") {
                detailRow("Name", object.name)
                if !object.namespace.isEmpty { detailRow("Namespace", object.namespace) }
                detailRow("Created", "\(Fmt.mediumDate(object.creationDate)) (\(Fmt.age(object.creationDate)))")
                if let controlledBy = object.controlledBy {
                    detailRow("Controlled By", controlledBy)
                }
            }

            if !kind.columns.isEmpty {
                Section("Details") {
                    ForEach(kind.columns) { column in
                        LabeledContent(column.title) {
                            let cell = column.cell(object, rowContext)
                            if column.style == .badge {
                                StatusBadge(text: cell.text, tone: cell.tone ?? .neutral)
                            } else {
                                Text(cell.text)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(cell.text)
                            }
                        }
                    }
                }
            }

            if kind == .pods {
                PodContainersSection(object: object)
            }
            if kind == .configMaps {
                DataSection(object: object, isSecret: false)
            }
            if kind == .secrets {
                DataSection(object: object, isSecret: true)
            }

            let conditions = object.raw["status"]["conditions"].array
            if !conditions.isEmpty {
                Section("Conditions") {
                    ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
                        ConditionRow(condition: condition)
                    }
                }
            }

            if !object.labels.isEmpty {
                Section("Labels") {
                    chipGrid(object.labels)
                }
            }
            if !object.annotations.isEmpty {
                Section("Annotations") {
                    ForEach(object.annotations.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(value).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }

    private func chipGrid(_ dict: [String: String]) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(dict.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                LabelChip(text: "\(key)=\(value)")
            }
        }
    }
}

private struct ConditionRow: View {
    let condition: JSONValue

    var body: some View {
        let type = condition["type"].stringValue
        let isTrue = condition["status"].stringValue == "True"
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(isTrue ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(type).font(.callout)
                Spacer()
                Text(condition["status"].stringValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let message = condition["message"].stringValue
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct PodContainersSection: View {
    let object: KubeObject

    var body: some View {
        Section("Containers") {
            ForEach(containerRows, id: \.name) { row in
                HStack(spacing: 8) {
                    Circle()
                        .fill(row.tone.color)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.callout)
                        Text(row.image)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(row.state).font(.caption)
                        if row.restarts > 0 {
                            Text("\(row.restarts) restarts")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private struct ContainerRow {
        let name: String
        let image: String
        let state: String
        let restarts: Int
        let tone: StatusTone
    }

    private var containerRows: [ContainerRow] {
        let statuses = object.raw["status"]["containerStatuses"].array
            + object.raw["status"]["initContainerStatuses"].array
        let specs = object.raw["spec"]["containers"].array
            + object.raw["spec"]["initContainers"].array

        return specs.map { spec in
            let name = spec["name"].stringValue
            let status = statuses.first { $0["name"].stringValue == name } ?? .null
            var stateText = "Unknown"
            var tone = StatusTone.neutral
            let state = status["state"]
            if !state["running"].isNull {
                stateText = "Running"
                tone = status["ready"].bool == true ? .ok : .warn
            } else if !state["waiting"].isNull {
                stateText = state["waiting"]["reason"].string ?? "Waiting"
                tone = .warn
            } else if !state["terminated"].isNull {
                stateText = state["terminated"]["reason"].string ?? "Terminated"
                tone = stateText == "Completed" ? .neutral : .bad
            }
            return ContainerRow(
                name: name,
                image: spec["image"].stringValue,
                state: stateText,
                restarts: status["restartCount"].int ?? 0,
                tone: tone
            )
        }
    }
}

private struct DataSection: View {
    let object: KubeObject
    let isSecret: Bool
    @State private var revealedKeys: Set<String> = []

    var body: some View {
        Section(isSecret ? "Data (base64 decoded)" : "Data") {
            let data = object.raw["data"].object.sorted(by: { $0.key < $1.key })
            if data.isEmpty {
                Text("Empty").foregroundStyle(.secondary)
            }
            ForEach(data, id: \.key) { key, value in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(key).font(.caption.monospaced().weight(.semibold))
                        Spacer()
                        if isSecret {
                            Button {
                                if revealedKeys.contains(key) {
                                    revealedKeys.remove(key)
                                } else {
                                    revealedKeys.insert(key)
                                }
                            } label: {
                                Image(systemName: revealedKeys.contains(key) ? "eye.slash" : "eye")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text(displayValue(key: key, raw: value.stringValue))
                        .font(.caption.monospaced())
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .foregroundStyle(isSecret && !revealedKeys.contains(key) ? .secondary : .primary)
                }
            }
        }
    }

    private func displayValue(key: String, raw: String) -> String {
        guard isSecret else { return raw }
        guard revealedKeys.contains(key) else { return "••••••••" }
        guard let data = Data(base64Encoded: raw) else { return "(invalid base64)" }
        return String(data: data, encoding: .utf8) ?? "(binary data, \(data.count) bytes)"
    }
}

// MARK: - Pods of a workload or node

private struct WorkloadPodsTab: View {
    @Environment(AppModel.self) private var model
    let object: KubeObject
    let kind: ResourceKind

    @State private var pods: [KubeObject] = []
    @State private var loading = true
    @State private var error: String?

    /// Nodes list their pods via a spec.nodeName field selector; workloads
    /// via their matchLabels selector.
    private var isNode: Bool { kind == .nodes }

    var body: some View {
        Group {
            if !isNode && KindHelpers.podSelectorString(object) == nil {
                ContentUnavailableView(
                    "No Selector",
                    systemImage: "cube",
                    description: Text("This workload has no matchLabels selector to find pods with.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading && pods.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack {
                    ErrorBanner(message: error) { Task { await load() } }
                    Spacer()
                }
            } else if pods.isEmpty {
                ContentUnavailableView(
                    "No Pods",
                    systemImage: "cube",
                    description: Text(isNode
                        ? "No pods are running on this node."
                        : "No pods currently match this workload's selector.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(pods.count) pods")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open in Pods") { jump(selectPod: nil) }
                            .controlSize(.small)
                    }
                    .padding(8)
                    Divider()
                    List(pods) { pod in
                        Button {
                            jump(selectPod: pod)
                        } label: {
                            podRow(pod)
                        }
                        .buttonStyle(.plain)
                        .help("Show in Pods, filtered to this \(kind.kindName)")
                    }
                }
            }
        }
        .task(id: object.id) {
            await load()
        }
    }

    private func jump(selectPod: KubeObject?) {
        if isNode {
            model.jumpToPods(
                selector: "spec.nodeName=\(object.name)",
                isFieldSelector: true,
                filterLabel: "Node \(object.name)",
                namespace: nil,
                selectNamespace: selectPod?.namespace,
                selectName: selectPod?.name
            )
        } else {
            guard let selector = KindHelpers.podSelectorString(object) else { return }
            model.jumpToPods(
                selector: selector,
                filterLabel: "\(kind.kindName) \(object.name)",
                namespace: object.namespace,
                selectName: selectPod?.name
            )
        }
    }

    private func podRow(_ pod: KubeObject) -> some View {
        let (statusText, tone) = KindHelpers.podStatus(pod)
        return HStack(spacing: 8) {
            Circle()
                .fill(tone.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(pod.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((isNode ? "\(pod.namespace) · " : "")
                    + "\(KindHelpers.podReady(pod)) ready · \(statusText) · \(Fmt.age(pod.creationDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let fetched: [KubeObject]
            if isNode {
                fetched = try await Kubectl.pods(
                    matching: "spec.nodeName=\(object.name)",
                    isFieldSelector: true,
                    namespace: nil,
                    context: model.selectedContext
                )
            } else if let selector = KindHelpers.podSelectorString(object) {
                fetched = try await Kubectl.pods(
                    matching: selector,
                    namespace: object.namespace.isEmpty ? nil : object.namespace,
                    context: model.selectedContext
                )
            } else {
                fetched = []
            }
            pods = fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch is CancellationError {
        } catch let fetchError {
            error = fetchError.localizedDescription
        }
        loading = false
    }
}

// MARK: - YAML

private struct YAMLTab: View {
    @Environment(AppModel.self) private var model
    let object: KubeObject
    let kind: ResourceKind

    @State private var yaml = ""
    @State private var draft = ""
    @State private var isEditing = false
    @State private var loading = false
    @State private var applying = false
    @State private var errorMessage: String?
    @State private var appliedMessage: String?
    @State private var showExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if isEditing {
                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                        .padding(.bottom, 4)
                }
                YAMLEditor(text: $draft)
            } else if loading && yaml.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if let errorMessage {
                Spacer()
                ErrorBanner(message: errorMessage) { Task { await load() } }
                Spacer()
            } else {
                YAMLTextView(text: yaml)
            }
        }
        .task(id: "\(object.id)/\(object.resourceVersion)") {
            if !isEditing { await load() }
        }
        .sheet(isPresented: $showExpanded) {
            YAMLExpandedEditorSheet(
                title: "\(kind.kindName) \(object.name)",
                initialText: isEditing ? draft : ManifestCleaner.editable(yaml),
                apply: { edited in try await model.applyYAML(edited) },
                onApplied: { message in
                    appliedMessage = message
                    isEditing = false
                    Task { await load() }
                }
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if isEditing {
                Label("Editing — changes apply via kubectl apply", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") {
                    isEditing = false
                    errorMessage = nil
                }
                Button(applying ? "Applying…" : "Apply") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(applying || draft.isEmpty)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Apply changes (⌘S)")
            } else {
                if let appliedMessage {
                    Label(appliedMessage, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    Pasteboard.copy(yaml)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(yaml.isEmpty)
                Button {
                    showExpanded = true
                } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Open in a larger editor")
                .disabled(yaml.isEmpty || loading)
                Button {
                    draft = ManifestCleaner.editable(yaml)
                    appliedMessage = nil
                    errorMessage = nil
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(yaml.isEmpty || loading)
            }
        }
        .controlSize(.small)
        .padding(8)
    }

    private func apply() {
        applying = true
        errorMessage = nil
        Task {
            do {
                let message = try await model.applyYAML(draft)
                appliedMessage = message
                applying = false
                isEditing = false
                await load()
            } catch is CancellationError {
                applying = false
            } catch {
                errorMessage = error.localizedDescription
                applying = false
            }
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            yaml = try await Kubectl.fetchYAML(
                kind: kind,
                name: object.name,
                namespace: object.namespace.isEmpty ? nil : object.namespace,
                context: model.selectedContext
            )
        } catch is CancellationError {
        } catch let fetchError {
            errorMessage = fetchError.localizedDescription
        }
        loading = false
    }
}

// MARK: - Events

private struct EventsTab: View {
    @Environment(AppModel.self) private var model
    let object: KubeObject
    let kind: ResourceKind

    @State private var events: [KubeObject] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading && events.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack {
                    ErrorBanner(message: error) { Task { await load() } }
                    Spacer()
                }
            } else if events.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "bell",
                    description: Text("No recent events reference this \(kind.kindName).")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(events) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            StatusBadge(
                                text: event.raw["type"].stringValue,
                                tone: event.raw["type"].stringValue == "Warning" ? .warn : .neutral
                            )
                            Text(event.raw["reason"].stringValue)
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text(Fmt.age(ResourceKind.events.ageDate(event)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(event.raw["message"].stringValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .task(id: object.id) {
            await load()
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            events = try await Kubectl.events(
                forName: object.name,
                kindName: kind.kindName,
                namespace: object.namespace.isEmpty ? nil : object.namespace,
                context: model.selectedContext
            )
        } catch is CancellationError {
        } catch let fetchError {
            error = fetchError.localizedDescription
        }
        loading = false
    }
}
