import SwiftUI
import AppKit
import Combine

extension StatusTone {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        case .neutral: return .gray
        }
    }
}

enum TableMetrics {
    /// Uniform cell content height so rows are the same height on every
    /// resource list, with or without usage bars.
    static let rowHeight: CGFloat = 24
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Status as plain colored text, no capsule chrome.
struct StatusBadge: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        if text.isEmpty {
            Text("–").foregroundStyle(.tertiary)
        } else {
            Text(text)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
        }
    }
}

/// Usage cell: compact live-usage text on the leading edge, a
/// uniform fixed-width bar pinned to the trailing edge, slack in between —
/// text lines up with the other columns, bars form one aligned rail. The bar
/// encodes the spec — full width is the limit, the tick is the request — and
/// the exact numbers surface on hover. Bounded values get threshold colors;
/// relative values are neutral blue.
struct UsageBar: View {
    let text: String
    let usage: UsageValue?
    /// Non-nil when the text stands in for live usage the metrics API didn't
    /// return: dims it and explains why on hover, so spec'd requests can't be
    /// read as consumption.
    var fallback: MetricsStatus?
    /// Hover text for healthy cells (the request/limit numbers the compact
    /// text omits). `fallback` wins when both are set.
    var detail: String?

    static let barWidth: CGFloat = 96
    private static let barHeight: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverTask: Task<Void, Never>?
    @State private var showDetail = false

    var body: some View {
        row
    }

    /// Hover popover on the bar only — pointing at the drawing you're asking
    /// about, without popping while mousing across the rest of the row.
    /// Custom instead of .help(): the system tooltip's ~1.5s delay reads as
    /// "no tooltip here", and lowering the global NSInitialToolTipDelay made
    /// every other tooltip trigger-happy. The short debounce keeps a pointer
    /// sweeping across bars from strobing popovers.
    @ViewBuilder
    private func hoverDetail<Target: View>(_ target: Target) -> some View {
        if let help = fallback?.cellDetail ?? detail {
            target
                .onHover { inside in
                    hoverTask?.cancel()
                    if inside {
                        hoverTask = Task {
                            try? await Task.sleep(for: .milliseconds(180))
                            // The panel check runs after the debounce, by
                            // which point both hover events have settled.
                            if !Task.isCancelled, !DetailPanelHover.pointerInside { showDetail = true }
                        }
                    } else {
                        showDetail = false
                    }
                }
                .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                    Text(help)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                // Table cells are recycled: a row scrolled out during the
                // debounce must not resume and pop on a reused cell.
                .onDisappear {
                    hoverTask?.cancel()
                    showDetail = false
                }
        } else {
            target
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            if let usage {
                // Text stays on the leading edge with the other columns;
                // the slack sits between it and a fixed-width bar rail
                // pinned to the trailing edge. Vertical padding fattens the
                // bar's hover target without changing what's drawn.
                label
                Spacer(minLength: 4)
                hoverDetail(bar(usage).padding(.vertical, 6))
            } else {
                // No bar to hover — a fallback cell's diagnostic hangs off
                // the text instead.
                hoverDetail(label)
                Spacer(minLength: 0)
            }
        }
    }

    private func bar(_ usage: UsageValue) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary.opacity(0.6))
            // Fill never narrower than its height, so near-zero
            // usage renders as a dot, not a degenerate smear.
            Capsule()
                .fill(barColor(usage))
                .frame(width: max(Self.barHeight, Self.barWidth * min(1, usage.fraction)))
            // Request tick: usage left of it fits in the request; right of
            // it is burst headroom. Core-in-halo so it reads on the bare
            // track and on any fill color — with the roles swapped per
            // appearance: dark mode wants a white core in a dark halo,
            // light mode the inverse (a white core vanishes into the light
            // track, leaving the halo as two dark slivers).
            if let marker = usage.marker {
                RoundedRectangle(cornerRadius: 1.75)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.9))
                    .frame(width: 3.5, height: Self.barHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.95) : Color.black.opacity(0.6))
                            .frame(width: 1.5)
                    }
                    .offset(x: max(0, min(Self.barWidth - 3.5, Self.barWidth * marker - 1.75)))
            }
        }
        .frame(width: Self.barWidth, height: Self.barHeight)
    }

    private var label: some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(fallback == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    }

    private func barColor(_ usage: UsageValue) -> Color {
        guard usage.bounded else { return .blue.opacity(0.6) }
        if usage.fraction < 0.7 { return .green }
        if usage.fraction < 0.9 { return .orange }
        return .red
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    @State private var expanded = false

    private var isLong: Bool { message.count > 160 || message.contains("\n") }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                if expanded {
                    ScrollView {
                        Text(message)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                } else {
                    Text(message)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if isLong {
                    Button(expanded ? "Show Less" : "Show Full Error") {
                        expanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            Spacer()
            if isLong {
                Button {
                    Pasteboard.copy(message)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy error")
            }
            if let retry {
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.35)))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}

/// Simple wrapping layout used for label chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : x
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct LabelChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            .textSelection(.enabled)
    }
}

/// Makes the enclosing sheet window user-resizable. SwiftUI sheets on macOS
/// don't get a resizable style mask even when their content declares a
/// flexible frame, so the window has to be patched directly.
///
/// The mask is KVO-guarded, not one-shot: SwiftUI configures the sheet
/// window asynchronously and can stomp a mask inserted too early — a race
/// that made resizability intermittent on sheets whose content never
/// re-renders (a second update pass happened to re-assert it for sheets
/// that do). The observation puts the bit back whenever something strips it.
struct SheetWindowConfigurator: NSViewRepresentable {
    /// Enforced as the window's contentMinSize: a hand-inserted resizable
    /// mask comes with no floor, so without this the sheet can be collapsed
    /// into an empty pill. Should match the content's own frame minimums.
    var minSize = CGSize(width: 640, height: 480)

    final class Coordinator: NSObject {
        private weak var window: NSWindow?
        private var observation: NSKeyValueObservation?
        private var minSize = CGSize.zero

        func attach(_ window: NSWindow, minSize: CGSize) {
            self.minSize = minSize
            if self.window !== window {
                self.window = window
                observation = window.observe(\.styleMask) { window, _ in
                    // Hop to the main actor (window KVO fires there anyway,
                    // but the closure isn't statically isolated), and
                    // re-insert asynchronously — doing it inside the KVO
                    // callback would recurse into the observed setter.
                    Task { @MainActor [weak window] in
                        guard let window, !window.styleMask.contains(.resizable) else { return }
                        window.styleMask.insert(.resizable)
                    }
                }
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowDidResize(_:)),
                    name: NSWindow.didResizeNotification, object: window
                )
            }
            enforce()
        }

        @objc private func windowDidResize(_ note: Notification) {
            enforce()
        }

        /// SwiftUI's sheet machinery rewrites the window's sizing constraints
        /// after presentation, so nothing here can be set-and-forget: mask,
        /// floor, and current size are re-asserted on every update and every
        /// resize tick.
        private func enforce() {
            guard let window else { return }
            if !window.styleMask.contains(.resizable) {
                window.styleMask.insert(.resizable)
            }
            if window.contentMinSize != minSize {
                window.contentMinSize = minSize
            }
            let content = window.contentRect(forFrameRect: window.frame).size
            if content.width < minSize.width || content.height < minSize.height {
                window.setContentSize(CGSize(
                    width: max(content.width, minSize.width),
                    height: max(content.height, minSize.height)
                ))
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view, minSize] in
            if let window = view?.window { context.coordinator.attach(window, minSize: minSize) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { context.coordinator.attach(window, minSize: minSize) }
    }
}

/// Clears the table selection when the user clicks the empty area below the
/// rows — AppKit tables deselect there, but SwiftUI's Table bridge swallows
/// it. Installed as a `.background` of the Table so its own frame identifies
/// which scroll view is "the" table; clicks on the header (sorting), the
/// scrollers, the safe-area banners, and anything overlaying the table (the
/// detail panel's own lists included) are deliberately ignored.
struct TableEmptyAreaDeselector: NSViewRepresentable {
    var onEmptyClick: @MainActor () -> Void

    final class Coordinator {
        // nonisolated(unsafe): deinit is nonisolated and may not touch
        // MainActor state; the coordinator deallocates with its view on the
        // main thread, so the access is main-thread in practice.
        nonisolated(unsafe) var monitor: Any?
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak view] event in
            MainActor.assumeIsolated {
                guard let view, let window = view.window, event.window === window else { return }
                let point = event.locationInWindow
                let ourFrame = view.convert(view.bounds, to: nil)
                guard ourFrame.contains(point) else { return }
                guard let hit = window.contentView?.hitTest(point) else { return }
                if hit is NSScroller { return }

                // Walk up from the hit: bail on header views, find the table.
                var table: NSTableView?
                var current: NSView? = hit
                while let node = current {
                    if node is NSTableHeaderView { return }
                    if let found = node as? NSTableView { table = found; break }
                    current = node.superview
                }
                // The empty area below the rows hits the clip view, whose
                // document is the table.
                if table == nil, let clip = hit as? NSClipView {
                    table = clip.documentView as? NSTableView
                }
                guard let table, let scroll = table.enclosingScrollView else { return }

                // Only the main table: its scroll view spans this background
                // view's frame. The detail panel's inner lists (also
                // NSTableView-backed) are smaller overlays — ignore them.
                let scrollFrame = scroll.convert(scroll.bounds, to: nil)
                guard abs(scrollFrame.midX - ourFrame.midX) < 2, abs(scrollFrame.width - ourFrame.width) < 2 else { return }

                if table.row(at: table.convert(point, from: nil)) == -1 {
                    onEmptyClick()
                }
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Custom detail split panel

/// Whether the pointer is currently over the detail panel. Hover-triggered
/// UI in the table underneath must check this: AppKit tracking areas fire on
/// geometry alone, so a usage bar covered by the panel still gets hover
/// events and would pop its detail through the panel.
@MainActor
enum DetailPanelHover {
    static var pointerInside = false
}

extension View {
    /// Right-side detail panel with a fully controlled divider: hard width
    /// clamping and drag-to-close. Replaces the native inspector, which does
    /// not reliably enforce its width limits during aggressive drags. Overlays
    /// the content rather than splitting it, so opening the panel never
    /// reflows the table underneath.
    func detailPanel<Panel: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder panel: @escaping () -> Panel
    ) -> some View {
        modifier(DetailPanelModifier(isPresented: isPresented, panel: panel))
    }
}

private struct DetailPanelModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let panel: () -> Panel

    @AppStorage("detail-panel-width") private var panelWidth = 440.0
    @State private var dragStartWidth: Double?
    /// Live width during a drag. @State, not @AppStorage: writing defaults on
    /// every mouse-move frame re-evaluated the entire window (Table included)
    /// per frame; the persisted value commits once, on drag end.
    @State private var dragWidth: Double?

    private static var minWidth: Double { 330 }

    func body(content: Content) -> some View {
        GeometryReader { geo in
            // The panel overlays the list instead of splitting with it: the
            // table keeps its full width and column layout when the panel
            // opens — rows are covered, never reflowed.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    if isPresented {
                        HStack(spacing: 0) {
                            splitter(totalWidth: geo.size.width)
                            panel()
                                .frame(width: clamped(dragWidth ?? panelWidth, totalWidth: geo.size.width))
                                .frame(maxHeight: .infinity)
                        }
                        .background(.regularMaterial)
                        .shadow(color: .black.opacity(0.22), radius: 10, x: -3)
                        .onHover { DetailPanelHover.pointerInside = $0 }
                        .onDisappear { DetailPanelHover.pointerInside = false }
                        // The exit hover event is missed when the pointer
                        // leaves via Cmd-Tab or a space switch; without this
                        // reset the stuck flag suppresses every usage popover
                        // until the panel is hovered again.
                        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                            DetailPanelHover.pointerInside = false
                        }
                    }
                }
        }
    }

    /// The panel may take at most 780pt and must leave the list ~500pt.
    private func maxWidth(totalWidth: CGFloat) -> Double {
        max(Self.minWidth + 30, min(780, Double(totalWidth) - 500))
    }

    private func clamped(_ width: Double, totalWidth: CGFloat) -> Double {
        min(max(width, Self.minWidth), maxWidth(totalWidth: totalWidth))
    }

    private func splitter(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                // Global coordinates: the splitter itself moves during the
                // drag, so local-space translations feed back and jitter.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = panelWidth }
                        let proposed = (dragStartWidth ?? panelWidth) - Double(value.translation.width)
                        dragWidth = clamped(proposed, totalWidth: totalWidth)
                    }
                    .onEnded { value in
                        let proposed = (dragStartWidth ?? panelWidth) - Double(value.translation.width)
                        // Persist once per drag, not once per frame.
                        panelWidth = clamped(proposed, totalWidth: totalWidth)
                        dragWidth = nil
                        dragStartWidth = nil
                        // Dragging well past the minimum closes the panel.
                        if proposed < Self.minWidth - 70 {
                            isPresented = false
                        }
                    }
            )
    }
}

// MARK: - Shared toolbar controls

struct NamespacePicker: View {
    @Environment(AppModel.self) private var model

    /// The live list, plus the current selection if it vanished (deleted
    /// namespace) so the picker never shows an empty selection.
    private var items: [String] {
        var items = model.namespaces
        if let selected = model.selectedNamespace, !items.contains(selected) {
            items.append(selected)
            items.sort()
        }
        return items
    }

    var body: some View {
        Picker("Namespace", selection: Binding(
            get: { model.selectedNamespace },
            set: { model.setNamespace($0) }
        )) {
            Text("All Namespaces").tag(String?.none)
            if !items.isEmpty {
                Divider()
                ForEach(items, id: \.self) { namespace in
                    Text(namespace).tag(String?.some(namespace))
                }
            }
        }
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .help("Filter by namespace")
    }
}

struct RefreshControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker("Auto-refresh", selection: Binding(
                get: { model.refreshSeconds },
                set: { model.refreshSeconds = $0 }
            )) {
                Text("Off").tag(0)
                Text("Every 2s").tag(2)
                Text("Every 5s").tag(5)
                Text("Every 10s").tag(10)
                Text("Every 30s").tag(30)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Auto-refresh", systemImage: "timer")
        }
        .help("Auto-refresh interval")

        Button {
            model.requestRefresh()
        } label: {
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .help("Refresh now (⌘R)")
    }
}
