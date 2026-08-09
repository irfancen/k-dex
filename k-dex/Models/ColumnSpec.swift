import Foundation

nonisolated enum StatusTone: Sendable {
    case ok, warn, bad, neutral
}

/// One rendered table cell: text plus optional badge tone or usage bar.
/// Produced by a single closure so status helpers run once per cell, not
/// once per attribute.
nonisolated struct Cell: Sendable {
    var text: String
    var tone: StatusTone?
    var usage: UsageValue?
    /// Non-nil when `text` is spec'd requests/limits standing in for live
    /// usage the metrics API didn't provide. Carries the reason so the cell
    /// can be dimmed and explained rather than misread as consumption —
    /// "100m / 500m" is a very different claim as requests than as usage.
    var fallback: MetricsStatus?
    /// Hover tooltip: the exact numbers a compact cell omits (request/limit
    /// behind a usage bar's geometry).
    var detail: String?

    init(
        text: String,
        tone: StatusTone? = nil,
        usage: UsageValue? = nil,
        fallback: MetricsStatus? = nil,
        detail: String? = nil
    ) {
        self.text = text
        self.tone = tone
        self.usage = usage
        self.fallback = fallback
        self.detail = detail
    }
}

/// A table column for a resource kind: title, layout hints, presentation
/// style, and one extractor producing the whole cell.
nonisolated struct ColumnSpec: Identifiable, Sendable {
    enum Style: Sendable {
        case plain
        /// Colored status text.
        case badge
        /// Caption text with a usage bar underneath (bar hidden when the
        /// cell has no usage value, but the compact styling is kept).
        case usage
    }

    let title: String
    let minWidth: CGFloat?
    let idealWidth: CGFloat?
    let maxWidth: CGFloat?
    let style: Style
    let cell: @Sendable (KubeObject, RowContext) -> Cell

    var id: String { title }

    init(
        _ title: String,
        min: CGFloat? = nil,
        ideal: CGFloat? = nil,
        max: CGFloat? = nil,
        style: Style = .plain,
        cell: @escaping @Sendable (KubeObject, RowContext) -> Cell
    ) {
        self.title = title
        self.minWidth = min
        self.idealWidth = ideal
        self.maxWidth = max
        self.style = style
        self.cell = cell
    }

    /// Convenience for plain text columns.
    init(
        _ title: String,
        min: CGFloat? = nil,
        ideal: CGFloat? = nil,
        max: CGFloat? = nil,
        value: @escaping @Sendable (KubeObject, RowContext) -> String
    ) {
        self.init(title, min: min, ideal: ideal, max: max, style: .plain) { object, ctx in
            Cell(text: value(object, ctx))
        }
    }

    /// Column whose cell is one JSON-path lookup — the dominant shape in the
    /// enrichment table. `path` walks `object.raw`; strings render verbatim,
    /// numbers and bools via `displayString`, missing values as "".
    static func text(
        _ title: String,
        min: CGFloat? = nil,
        ideal: CGFloat? = nil,
        max: CGFloat? = nil,
        _ path: String...
    ) -> ColumnSpec {
        ColumnSpec(title, min: min, ideal: ideal, max: max) { object, _ in
            var value = object.raw
            for key in path { value = value[key] }
            return value.displayString
        }
    }
}

/// Type-aware table sorting: key extraction and comparison. Outside the view
/// so the app's most subtle non-UI logic is testable — the comparator's
/// strict-weak-ordering obligations in particular (see the ordering-law
/// tests), which Swift's sorted(by:) violates *silently* when broken.
nonisolated enum ColumnSorting {
    static func numericValue(_ text: String, columnID: String) -> Double? {
        guard let token = text.split(separator: " ").first.map(String.init), token != "–" else { return nil }
        // "1/2" ready ratios → sort by the ready count. isFinite for the
        // same reason as below: "nan/1" must not poison the comparator.
        if token.contains("/") {
            let parts = token.split(separator: "/")
            if parts.count == 2, let ready = Double(parts[0]), ready.isFinite { return ready }
        }
        if columnID.hasPrefix("CPU") { return Quantity.cpuMillicores(token) }
        if columnID.hasPrefix("Memory") || columnID.hasPrefix("Mem") { return Quantity.memoryBytes(token) }
        // isFinite: Double("nan")/Double("inf") parse, and a single NaN key
        // breaks the comparator's strict weak ordering — sorted(by:) then
        // silently mis-sorts unrelated rows rather than trapping.
        if let plain = Double(token), plain.isFinite { return plain }
        return Quantity.memoryBytes(token) // catches "1Gi" capacities etc.
    }

    /// One pre-extracted key per row. Sorting is decorate–sort–undecorate:
    /// cell extraction and quantity parsing run once per row here, never
    /// inside the O(n log n) comparator.
    struct SortKey {
        var text = ""
        var tieBreak = ""
        var numeric: Double?
        var date: Date?
    }

    static func sortKey(
        columnID: String,
        column: ColumnSpec?,
        object: KubeObject,
        kind: ResourceKind,
        ctx: RowContext
    ) -> SortKey {
        switch columnID {
        case "name":
            return SortKey(text: object.name, tieBreak: object.namespace)
        case "Namespace":
            return SortKey(text: object.namespace, tieBreak: object.name)
        case "Age":
            return SortKey(date: kind.ageDate(object) ?? .distantPast)
        case "Last Restart":
            return SortKey(date: lastRestartDate(object, kind: kind, ctx: ctx) ?? .distantPast)
        default:
            guard let column else { return SortKey() }
            let text = column.cell(object, ctx).text
            return SortKey(text: text, numeric: numericValue(text, columnID: columnID))
        }
    }

    static func lastRestartDate(_ object: KubeObject, kind: ResourceKind, ctx: RowContext) -> Date? {
        if kind == .pods { return KindHelpers.podLastRestart(object) }
        return ctx.workloadUsage["\(object.namespace)/\(object.name)"]?.lastRestart
    }

    static func compare(_ lhs: SortKey, _ rhs: SortKey) -> ComparisonResult {
        if let left = lhs.date, let right = rhs.date {
            // Ascending = newest first.
            if left == right { return .orderedSame }
            return left > right ? .orderedAscending : .orderedDescending
        }
        if let left = lhs.numeric, let right = rhs.numeric {
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
        // Numeric rows sort before non-numeric ("–") so the ordering is total.
        if lhs.numeric != nil { return .orderedAscending }
        if rhs.numeric != nil { return .orderedDescending }
        let result = lhs.text.localizedStandardCompare(rhs.text)
        return result == .orderedSame ? lhs.tieBreak.localizedStandardCompare(rhs.tieBreak) : result
    }
}

nonisolated enum ResourceCategory: String, CaseIterable, Identifiable, Sendable {
    case workloads, network, config, storage, access, cluster, crd, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workloads: return "Workloads"
        case .network: return "Network"
        case .config: return "Config"
        case .storage: return "Storage"
        case .access: return "Access Control"
        case .cluster: return "Cluster"
        case .crd: return "Custom Resources"
        case .other: return "Other"
        }
    }
}

nonisolated enum SidebarItem: Hashable, Sendable {
    case overview
    case resource(ResourceKind)
    case helm
    /// Transient: clicking a category row toggles its expansion, then the
    /// selection is bounced back to the previous item.
    case category(String)
}

/// Curated metadata for a well-known kind: how it's presented and which
/// actions it supports. Identity comes from API discovery; this is the
/// editorial layer discovery can't provide (columns, icons, grouping).
nonisolated struct KindEnrichment: Sendable {
    var displayName: String
    var icon: String
    var category: ResourceCategory
    var visibleByDefault = true
    var supportsLogs = false
    var supportsRestart = false
    var supportsScale = false
    var supportsPortForward = false
    var showsPods = false
    var columns: [ColumnSpec] = []
}
