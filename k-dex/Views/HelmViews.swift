import SwiftUI

struct HelmListView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("columns-helm") private var columnCustomization = TableColumnCustomization<HelmRelease>()
    @State private var sortOrder: [KeyPathComparator<HelmRelease>] = []

    var body: some View {
        @Bindable var model = model
        let rows = sortOrder.isEmpty
            ? model.filteredHelmReleases
            : model.filteredHelmReleases.sorted(using: sortOrder)

        Table(rows, selection: $model.selectedHelmID, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("Name", value: \.name) { release in
                HStack(spacing: 7) {
                    Image(systemName: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(release.name)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                .frame(height: TableMetrics.rowHeight, alignment: .leading)
            }
            .width(min: 130, ideal: 190)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Namespace", value: \.namespace) { release in
                Text(release.namespace)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: TableMetrics.rowHeight, alignment: .leading)
            }
            .width(min: 100, ideal: 120, max: 180)
            .customizationID("namespace")

            TableColumn("Chart", value: \.chart) { release in
                Text(release.chart)
                    .lineLimit(1)
                    .frame(height: TableMetrics.rowHeight, alignment: .leading)
            }
            .width(min: 120, ideal: 190)
            .customizationID("chart")

            TableColumn("App Version", value: \.appVersion) { release in
                Text(release.appVersion)
                    .lineLimit(1)
                    .frame(height: TableMetrics.rowHeight, alignment: .leading)
            }
            .width(min: 88, ideal: 95, max: 130)
            .customizationID("appVersion")

            TableColumn("Revision", value: \.revision) { release in
                Text(String(release.revision))
                    .monospacedDigit()
                    .frame(height: TableMetrics.rowHeight, alignment: .leading)
            }
            .width(min: 62, ideal: 66, max: 84)
            .customizationID("revision")

            TableColumn("Status", value: \.status) { release in
                StatusBadge(text: release.status, tone: release.statusTone)
                    .frame(height: TableMetrics.rowHeight, alignment: .leading)
            }
            .width(min: 96, ideal: 110, max: 160)
            .customizationID("status")

            TableColumn("Updated", value: \.updatedTime) { release in
                Text(Fmt.age(release.updated))
                    .foregroundStyle(.secondary)
                    .frame(height: TableMetrics.rowHeight, alignment: .leading)
            }
            .width(min: 60, ideal: 68, max: 90)
            .customizationID("updated")
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .onExitCommand { model.selectedHelmID = nil }
        .contextMenu(forSelectionType: String.self) { ids in
            if let release = rows.first(where: { ids.contains($0.id) }) {
                Button("Copy Name") { Pasteboard.copy(release.name) }
                Button("Copy Chart") { Pasteboard.copy(release.chart) }
            }
        }
        .searchable(text: $model.searchText, prompt: "Filter releases")
        .overlay {
            if model.isLoading && rows.isEmpty && model.lastError == nil {
                ProgressView()
            } else if rows.isEmpty && model.lastError == nil && !model.isLoading {
                ContentUnavailableView(
                    "No Helm Releases",
                    systemImage: "shippingbox",
                    description: Text("No Helm releases were found in this scope.")
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = model.lastError {
                ErrorBanner(message: error) { model.requestRefresh() }
            }
        }
        .detailPanel(isPresented: inspectorPresented) {
            if let release = model.selectedHelmRelease {
                HelmDetailView(release: release)
                    .id(release.id) // reset tab + reveal state per release
            }
        }
        .toolbar {
            ToolbarItemGroup {
                NamespacePicker()
                PortForwardsButton()
                RefreshControls()
            }
        }
        .navigationTitle("Helm Releases")
        .navigationSubtitle(model.selectedNamespace.map { "Namespace: \($0)" } ?? "All namespaces")
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { model.selectedHelmID != nil },
            set: { if !$0 { model.selectedHelmID = nil } }
        )
    }
}

struct HelmDetailView: View {
    @Environment(AppModel.self) private var model
    let release: HelmRelease

    private enum Tab: String, CaseIterable {
        case overview = "Overview"
        case values = "Values"
        case manifest = "Manifest"
        case notes = "Notes"
    }

    @State private var tab: Tab = .overview
    // Helm values and manifests routinely embed credentials (chart passwords,
    // registry auth, rendered Secrets) — require an explicit reveal, like the
    // Secret data section does.
    @State private var revealedValues = false
    @State private var revealedManifest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            switch tab {
            case .overview:
                overview
            case .values:
                secretGated(revealed: $revealedValues, what: "values") {
                    YAMLTextView(text: release.values.isNull || release.values.object.isEmpty
                        ? "# No user-supplied values"
                        : release.values.prettyJSONString())
                }
            case .manifest:
                secretGated(revealed: $revealedManifest, what: "manifest") {
                    YAMLTextView(text: release.manifest.isEmpty ? "# Manifest unavailable" : release.manifest)
                }
            case .notes:
                ScrollView {
                    Text(release.notes.isEmpty ? "No notes." : release.notes)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .padding(.leading, 8) // grab gutter: keeps the resize cursor usable next to text views
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    model.selectedHelmID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
                Text("\(release.chart) · \(release.namespace) · rev \(release.revision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                StatusBadge(text: release.status, tone: release.statusTone)
                    .font(.caption)
            }
            Text(release.name)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func secretGated(
        revealed: Binding<Bool>,
        what: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if revealed.wrappedValue {
            content()
        } else {
            ContentUnavailableView {
                Label("Hidden", systemImage: "eye.slash")
            } description: {
                Text("Release \(what) can contain passwords, tokens, and other secrets.")
            } actions: {
                Button("Show \(what.capitalized)") { revealed.wrappedValue = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var overview: some View {
        Form {
            Section("Release") {
                LabeledContent("Name", value: release.name)
                LabeledContent("Namespace", value: release.namespace)
                LabeledContent("Chart", value: release.chart)
                LabeledContent("App Version", value: release.appVersion.isEmpty ? "–" : release.appVersion)
                LabeledContent("Revision", value: String(release.revision))
                LabeledContent("Updated", value: Fmt.mediumDate(release.updated))
                LabeledContent("Status") {
                    StatusBadge(text: release.status, tone: release.statusTone)
                }
            }

            if !release.history.isEmpty {
                Section("History") {
                    ForEach(release.history) { revision in
                        HStack {
                            Text("Revision \(revision.revision)")
                                .font(.callout)
                            Spacer()
                            Text(revision.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Fmt.age(revision.date))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
