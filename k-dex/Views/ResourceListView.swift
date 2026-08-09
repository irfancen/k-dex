import SwiftUI

struct ResourceListView: View {
    @Environment(AppModel.self) private var model
    let kind: ResourceKind

    /// Arrays: batch delete/restart act on the whole selection; single-row
    /// actions are one-element batches through the same dialogs.
    @State private var deleteCandidates: [KubeObject] = []
    @State private var scaleCandidate: KubeObject?
    @State private var forwardCandidate: KubeObject?
    @State private var restartCandidates: [KubeObject] = []
    @State private var showCreateSheet = false
    @State private var sortOrder: [ColumnSort] = []
    // Persists user-resized/reordered/hidden columns per resource kind.
    @SceneStorage private var columnCustomization: TableColumnCustomization<KubeObject>
    /// The header-click sort, persisted per kind as "columnID|direction" so
    /// sorting Pods by Age survives navigation and relaunch.
    @SceneStorage private var storedSort: String

    init(kind: ResourceKind) {
        self.kind = kind
        _columnCustomization = SceneStorage(wrappedValue: TableColumnCustomization<KubeObject>(), "columns-\(kind.id)")
        _storedSort = SceneStorage(wrappedValue: "", "sort-\(kind.id)")
        // Every table carries a visible sort: the default is expressed as a
        // real header selection, so what the indicator says and what the
        // rows do always agree. Hash-named kinds default to Age (forward =
        // newest first — dates sort inverted so the first header click gives
        // the useful direction); everything else to Name. A persisted user
        // choice replaces this in onAppear.
        let defaultsToAge = kind == .replicaSets || kind == .jobs || kind == .events
        _sortOrder = State(initialValue: [ColumnSort(id: defaultsToAge ? "Age" : "name", order: .forward)])
    }

    var body: some View {
        @Bindable var model = model
        let rowContext = model.listRowContext
        let rows = sortedRows(model.filteredObjects, rowContext)
        let showNamespace = kind.isNamespaced && model.selectedNamespace == nil
        let namespaceColumn = ColumnSpec("Namespace", ideal: 110, max: 180) { object, _ in object.namespace }
        let columns = showNamespace ? [namespaceColumn] + kind.columns : kind.columns

        Table(rows, selection: $model.selectedObjectIDs, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("Name", sortUsing: ColumnSort(id: "name")) { object in
                NameCell(object: object, kind: kind)
            }
            .width(min: 130, ideal: 190)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumnForEach(columns) { column in
                TableColumn(column.title, sortUsing: ColumnSort(id: column.id)) { object in
                    let cell = column.cell(object, rowContext)
                    Group {
                        switch column.style {
                        case .badge:
                            StatusBadge(text: cell.text, tone: cell.tone ?? .neutral)
                        case .usage:
                            UsageBar(text: cell.text, usage: cell.usage, fallback: cell.fallback, detail: cell.detail)
                        case .plain:
                            // Relative-time cells tick themselves: a
                            // per-cell TimelineView updates the text without
                            // re-rendering the table (a whole-table 1 Hz
                            // re-render raced selection clicks).
                            if column.title == "Age" || column.title == "Last Restart" {
                                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                    plainCellText(tickedText(column: column, object: object, base: rowContext, now: timeline.date), column: column)
                                }
                            } else {
                                plainCellText(cell.text, column: column)
                            }
                        }
                    }
                    .frame(height: TableMetrics.rowHeight, alignment: .leading)
                }
                .width(min: column.minWidth ?? column.idealWidth, ideal: column.idealWidth, max: column.maxWidth)
                .customizationID(column.id)
            }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        // Click-on-empty deselects, as in every AppKit table.
        .background(TableEmptyAreaDeselector { model.selectedObjectIDs = [] })
        .onAppear {
            // A stored choice beats the per-kind default the init installed.
            guard !storedSort.isEmpty else { return }
            let parts = storedSort.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return }
            sortOrder = [ColumnSort(id: String(parts[0]), order: parts[1] == "reverse" ? .reverse : .forward)]
        }
        .onChange(of: sortOrder) {
            storedSort = sortOrder.first.map { "\($0.id)|\($0.order == .reverse ? "reverse" : "forward")" } ?? ""
        }
        .onExitCommand { model.selectedObjectIDs = [] }
        .contextMenu(forSelectionType: String.self) { ids in
            let selected = rows.filter { ids.contains($0.id) }
            if selected.count > 1 {
                batchMenu(for: selected)
            } else if let object = selected.first {
                rowMenu(for: object)
            }
        }
        .searchable(text: $model.searchText, prompt: "Filter \(kind.displayName.lowercased())")
        .overlay {
            if model.isLoading && rows.isEmpty && model.lastError == nil {
                ProgressView()
            } else if rows.isEmpty && model.lastError == nil && !model.isLoading {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "No \(kind.displayName)" : "No Matches",
                    systemImage: kind.icon,
                    description: Text(scopeDescription)
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let error = model.lastError {
                    ErrorBanner(message: error) { model.requestRefresh() }
                }
                // Only where usage columns exist, and only once rows are on
                // screen — an empty list has nothing to mislead anyone about.
                if hasUsageColumns, !rows.isEmpty, let hint = model.metricsStatus.listHint {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.xaxis")
                            .foregroundStyle(.orange)
                        Text(hint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.08))
                }
                if kind == .pods, let filter = model.podFilter {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Showing pods of **\(filter.label)**")
                            .font(.callout)
                        Button {
                            model.clearPodFilter()
                        } label: {
                            Label("Clear Pod Filter", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Show all pods")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.blue.opacity(0.08))
                }
            }
        }
        .detailPanel(isPresented: inspectorPresented) {
            if let object = model.selectedObject {
                ResourceDetailView(
                    object: object,
                    kind: kind,
                    onDelete: kind.supportsDelete ? { deleteCandidates = [object] } : nil,
                    onScale: kind.supportsScale ? { scaleCandidate = object } : nil,
                    onForward: kind.supportsPortForward ? { forwardCandidate = object } : nil,
                    onRestart: kind.supportsRestart ? { restartCandidates = [object] } : nil
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if kind != .events && kind != .nodes {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("New \(kind.kindName)", systemImage: "plus")
                    }
                    .help("Create a new \(kind.kindName)")
                }
                if kind.isNamespaced {
                    NamespacePicker()
                }
                PortForwardsButton()
                RefreshControls()
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateResourceSheet(kind: kind, namespace: model.selectedNamespace)
        }
        .navigationTitle(kind.displayName)
        .navigationSubtitle(scopeDescription)
        .confirmationDialog(
            deleteCandidates.count == 1
                ? "Delete \(deleteCandidates.first?.name ?? "resource")?"
                : "Delete \(deleteCandidates.count) \(kind.displayName)?",
            isPresented: Binding(get: { !deleteCandidates.isEmpty }, set: { if !$0 { deleteCandidates = [] } })
        ) {
            Button(deleteCandidates.count == 1 ? "Delete" : "Delete \(deleteCandidates.count)", role: .destructive) {
                model.deleteObjects(deleteCandidates, kind: kind)
                model.selectedObjectIDs.subtract(deleteCandidates.map(\.id))
                deleteCandidates = []
            }
        } message: {
            // Verbatim: cluster-supplied names must render literally, and in
            // a multi-cluster tool "the cluster" is never specific enough.
            Text(verbatim: deleteMessage(for: deleteCandidates))
        }
        .confirmationDialog(
            restartCandidates.count == 1
                ? "Restart \(restartCandidates.first?.name ?? "workload")?"
                : "Restart \(restartCandidates.count) \(kind.displayName)?",
            isPresented: Binding(get: { !restartCandidates.isEmpty }, set: { if !$0 { restartCandidates = [] } })
        ) {
            Button(restartCandidates.count == 1 ? "Rollout Restart" : "Rollout Restart \(restartCandidates.count)") {
                model.restartObjects(restartCandidates, kind: kind)
                restartCandidates = []
            }
        } message: {
            Text(verbatim: restartMessage(for: restartCandidates))
        }
        .sheet(item: $scaleCandidate) { object in
            ScaleSheet(object: object, kind: kind)
        }
        .sheet(item: $forwardCandidate) { object in
            PortForwardSheet(object: object, kind: kind)
        }
        .alert("Action Failed", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private func deleteMessage(for objects: [KubeObject]) -> String {
        if objects.count == 1, let object = objects.first {
            var scope = object.namespace.isEmpty ? "" : " in namespace \(object.namespace)"
            scope += " on context \(model.selectedContext)"
            return "This deletes \(kind.kindName) \u{2068}\(object.name)\u{2069}\(scope) and cannot be undone."
        }
        guard !objects.isEmpty else { return "" }
        return "This deletes \(batchList(objects)) on context \(model.selectedContext) and cannot be undone."
    }

    /// Grouped by namespace so a cross-namespace batch names where things
    /// live (finding 9's requirement, kept under batching): "a, b and 1 more
    /// in default; c in kube-system". Every cluster-supplied string is
    /// bidi-isolated.
    private func batchList(_ objects: [KubeObject]) -> String {
        func nameList(_ group: [KubeObject], cap: Int) -> String {
            let names = group.prefix(cap).map { "\u{2068}\($0.name)\u{2069}" }.joined(separator: ", ")
            let more = group.count > cap ? " and \(group.count - cap) more" : ""
            return names + more
        }
        let groups = Dictionary(grouping: objects, by: \.namespace).sorted { $0.key < $1.key }
        if groups.count == 1, let only = groups.first {
            let place = only.key.isEmpty ? "" : " in namespace \u{2068}\(only.key)\u{2069}"
            return "\(nameList(only.value, cap: 5))\(place)"
        }
        return groups.map { namespace, group in
            "\(nameList(group, cap: 3)) in \u{2068}\(namespace)\u{2069}"
        }.joined(separator: "; ")
    }

    private func restartMessage(for objects: [KubeObject]) -> String {
        if objects.count == 1, let object = objects.first {
            let scope = object.namespace.isEmpty ? "" : " in namespace \(object.namespace)"
            return "This restarts every pod of \(kind.kindName) \u{2068}\(object.name)\u{2069}\(scope) on context \(model.selectedContext)."
        }
        guard !objects.isEmpty else { return "" }
        return "This restarts every pod of \(batchList(objects)) on context \(model.selectedContext)."
    }

    /// Context menu for a multi-row selection: only the actions that make
    /// sense as a batch (scale, port-forward, logs, YAML are single-target).
    @ViewBuilder
    private func batchMenu(for objects: [KubeObject]) -> some View {
        if kind.supportsRestart {
            Button {
                restartCandidates = objects
            } label: {
                Label("Restart \(objects.count) \(kind.displayName)", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        Button {
            Pasteboard.copy(objects.map(\.name).joined(separator: "\n"))
        } label: {
            Label("Copy Names", systemImage: "doc.on.doc")
        }
        if kind.supportsDelete {
            Divider()
            Button(role: .destructive) {
                deleteCandidates = objects
            } label: {
                Label("Delete \(objects.count) \(kind.displayName)", systemImage: "trash")
            }
        }
    }

    // MARK: Sorting

    /// Header-click sorting with type-aware comparisons (quantities, x/y
    /// ratios, numbers, dates). Decorate–sort–undecorate: keys are extracted
    /// once per row, never twice per comparison — cell extraction and
    /// quantity parsing are far too expensive for an O(n log n) comparator.
    private func sortedRows(_ rows: [KubeObject], _ ctx: RowContext) -> [KubeObject] {
        guard let sort = sortOrder.first else { return rows }
        let ascending = sort.order == .forward
        let column = kind.columns.first { $0.id == sort.id } // resolved once

        let keyed = rows.map { object in
            (row: object, key: ColumnSorting.sortKey(columnID: sort.id, column: column, object: object, kind: kind, ctx: ctx))
        }
        return keyed.sorted { lhs, rhs in
            let result = ColumnSorting.compare(lhs.key, rhs.key)
            guard result != .orderedSame else { return false }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }.map(\.row)
    }

    private var hasUsageColumns: Bool {
        kind.columns.contains { $0.style == .usage }
    }

    private func tickedText(column: ColumnSpec, object: KubeObject, base: RowContext, now: Date) -> String {
        var ctx = base
        ctx.now = now
        return column.cell(object, ctx).text
    }

    private func plainCellText(_ text: String, column: ColumnSpec) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(column.title == "Age" || column.title == "Namespace" ? .secondary : .primary)
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { model.selectedObject != nil },
            set: { if !$0 { model.selectedObjectIDs = [] } }
        )
    }

    private var scopeDescription: String {
        let scope: String
        if kind.isNamespaced {
            scope = model.selectedNamespace.map { "Namespace: \($0)" } ?? "All namespaces"
        } else {
            scope = "Cluster-wide"
        }
        return model.isWatching ? scope + " · Live" : scope
    }

    @ViewBuilder
    private func rowMenu(for object: KubeObject) -> some View {
        if kind == .nodes {
            Button {
                model.openDetail(object, tab: "pods")
            } label: {
                Label("Pods", systemImage: "cube")
            }
        }
        if kind.supportsLogs || kind.showsPods {
            Button {
                model.openDetail(object, tab: "logs")
            } label: {
                Label("Logs", systemImage: "text.alignleft")
            }
        }
        if kind.supportsScale {
            Button {
                scaleCandidate = object
            } label: {
                Label("Scale", systemImage: "arrow.up.arrow.down")
            }
        }
        if kind.supportsRestart {
            Button {
                restartCandidates = [object]
            } label: {
                Label("Restart", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        if kind.supportsPortForward {
            Button {
                forwardCandidate = object
            } label: {
                Label("Port Forward", systemImage: "arrow.left.arrow.right")
            }
        }
        Button {
            model.openDetail(object, tab: "yaml")
        } label: {
            Label("YAML", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        Button {
            Pasteboard.copy(object.name)
        } label: {
            Label("Copy Name", systemImage: "doc.on.doc")
        }
        if kind.supportsDelete {
            Divider()
            Button(role: .destructive) {
                deleteCandidates = [object]
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Sort token carried by sortable columns; comparison itself happens in
/// `sortedRows` where metrics context is available.
nonisolated struct ColumnSort: SortComparator, Hashable {
    typealias Compared = KubeObject
    var id: String
    var order: SortOrder = .forward

    func compare(_ lhs: KubeObject, _ rhs: KubeObject) -> ComparisonResult {
        .orderedSame
    }
}

private struct NameCell: View {
    let object: KubeObject
    let kind: ResourceKind

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: kind.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(object.name)
                .foregroundStyle(.blue)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: TableMetrics.rowHeight, alignment: .leading)
    }
}

struct ScaleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let object: KubeObject
    let kind: ResourceKind
    @State private var replicas: Int

    init(object: KubeObject, kind: ResourceKind) {
        self.object = object
        self.kind = kind
        _replicas = State(initialValue: object.raw["spec"]["replicas"].int ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scale \(object.name)")
                .font(.headline)
            LabeledContent("Current replicas", value: object.raw["spec"]["replicas"].displayString)
            Stepper(value: $replicas, in: 0...500) {
                TextField("Replicas", value: $replicas, format: .number)
                    .frame(width: 70)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Scale") {
                    model.scaleObject(object, kind: kind, replicas: replicas)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
