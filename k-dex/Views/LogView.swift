import SwiftUI
import AppKit

/// Log viewer for a single pod, or aggregated across a workload's pods
/// (kubectl -l selector --prefix), with timestamps and per-pod colored tags.
struct LogView: View {
    @Environment(AppModel.self) private var model
    let object: KubeObject
    let kind: ResourceKind
    /// False inside the expanded sheet, which would otherwise offer to
    /// expand itself.
    let allowsExpansion: Bool

    @State private var streamer = LogStreamer()
    @State private var container: String
    @State private var follow = true
    @State private var showTimestamps = true
    @State private var wrapLines = true
    @State private var showPrevious = false
    @State private var filter = ""
    @State private var showExpanded = false
    @AppStorage(SettingsKeys.logTail) private var tail = 500

    init(object: KubeObject, kind: ResourceKind, allowsExpansion: Bool = true) {
        self.object = object
        self.kind = kind
        self.allowsExpansion = allowsExpansion
        // Pods must name a container (kubectl errors on multi-container pods
        // otherwise); workloads default to all containers ("").
        let containers = kind == .pods
            ? object.raw["spec"]["containers"].array.map { $0["name"].stringValue }
            : []
        _container = State(initialValue: containers.first ?? "")
    }

    private var isAggregate: Bool { kind != .pods }
    private var selector: String? { isAggregate ? KindHelpers.podSelectorString(object) : nil }

    /// Pods carry containers at spec.*; workloads at spec.template.spec.*.
    private var containers: [String] {
        let spec = kind == .pods ? object.raw["spec"] : object.raw["spec"]["template"]["spec"]
        return (spec["containers"].array + spec["initContainers"].array)
            .map { $0["name"].stringValue }
    }

    private var visibleLines: [LogStreamer.Line] {
        guard !filter.isEmpty else { return streamer.lines }
        return streamer.lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        if isAggregate && selector == nil {
            ContentUnavailableView(
                "No Selector",
                systemImage: "text.alignleft",
                description: Text("This workload has no matchLabels selector to aggregate logs with.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                controls
                Divider()
                if let crash = crashInfo {
                    crashBanner(crash)
                    Divider()
                }
                LogTextView(
                    lines: visibleLines,
                    follow: follow && !showPrevious,
                    wrap: wrapLines,
                    onInteractiveScrollAway: { follow = false }
                )
                    .overlay {
                        if streamer.lines.isEmpty && streamer.isStreaming {
                            Text("Waiting for logs…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                if let status = streamer.statusMessage {
                    Divider()
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
            }
            // `follow` is deliberately absent: it only controls auto-scroll
            // pinning now, so toggling it (or scrolling up, which unchecks
            // it) must not restart the stream and lose the reading position.
            .task(id: "\(object.id)/\(container)/\(showTimestamps)/\(showPrevious)") {
                start()
            }
            .onDisappear {
                streamer.stop()
            }
            .sheet(isPresented: $showExpanded) {
                LogExpandedSheet(object: object, kind: kind)
            }
        }
    }

    private func start() {
        let target: LogStreamer.Target
        if let selector {
            target = .selector(selector, container: container.isEmpty ? nil : container)
        } else {
            target = .pod(name: object.name, container: container.isEmpty ? nil : container)
        }
        streamer.start(
            context: model.selectedContext,
            namespace: object.namespace,
            target: target,
            follow: !showPrevious, // always stream; the toggle only pins the scroll
            tail: max(tail, 10),
            timestamps: showTimestamps,
            previous: showPrevious
        )
    }

    // MARK: Crash awareness

    private struct CrashInfo {
        let container: String
        let reason: String
        let exitCode: Int?
        let at: Date?
        let restarts: Int
    }

    /// Last termination of the selected container, so crashed pods offer
    /// their previous instance's logs one click away.
    private var crashInfo: CrashInfo? {
        guard kind == .pods else { return nil }
        let statuses = object.raw["status"]["containerStatuses"].array
            + object.raw["status"]["initContainerStatuses"].array
        guard let status = statuses.first(where: { $0["name"].stringValue == container }) ?? statuses.first else {
            return nil
        }
        let restarts = status["restartCount"].int ?? 0
        let terminated = status["lastState"]["terminated"]
        let reason = terminated["reason"].string
        // A completed init container isn't a crash; require restarts or a
        // non-Completed termination.
        guard restarts > 0 || (reason != nil && reason != "Completed") else { return nil }
        return CrashInfo(
            container: status["name"].stringValue,
            reason: reason ?? "Restarted",
            exitCode: terminated["exitCode"].int,
            at: Fmt.parseDate(terminated["finishedAt"].string),
            restarts: restarts
        )
    }

    private func crashBanner(_ crash: CrashInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(crashText(crash))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(showPrevious ? "Show Current" : "Show Crash Logs") {
                showPrevious.toggle()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.1))
    }

    private func crashText(_ crash: CrashInfo) -> String {
        var parts = "\(crash.container) crashed — \(crash.reason)"
        if let code = crash.exitCode { parts += " (exit \(code))" }
        if let at = crash.at { parts += ", \(Fmt.age(at)) ago" }
        if crash.restarts > 0 { parts += " · \(crash.restarts) restart\(crash.restarts == 1 ? "" : "s")" }
        return parts
    }

    /// One row when the panel is wide enough, toggles and filter/actions on
    /// two rows when it isn't. Without the reflow (and the fixedSize on the
    /// toggle group) a narrow detail panel width-starves the toggle labels,
    /// which wrap letter-by-letter into vertical text.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                containerMenu
                toggles
                filterField
                Spacer()
                actionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    containerMenu
                    toggles
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    filterField
                    Spacer()
                    actionButtons
                }
            }
        }
        .controlSize(.small)
        .padding(8)
    }

    @ViewBuilder
    private var containerMenu: some View {
        if containers.count > 1 {
            // Menu + fixed label instead of Picker: NSPopUpButton derives
            // its width from its menu items (which differ per workload),
            // so no frame arrangement renders it consistently. A Menu's
            // button sizes to the label, which is pinned here.
            Menu {
                Picker("Container", selection: $container) {
                    Text("All Containers").tag("")
                    ForEach(containers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(container.isEmpty ? "All Containers" : container)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 118, alignment: .leading)
            }
            .fixedSize()
            .help("Container")
        }
    }

    private var toggles: some View {
        HStack(spacing: 10) {
            Toggle("Follow", isOn: $follow)
                .disabled(showPrevious)
                .help("Pin to the newest lines (scrolling up unpins)")
            Toggle("Time", isOn: $showTimestamps)
                .help("Show timestamps")
            Toggle("Wrap", isOn: $wrapLines)
                .help("Wrap long lines")
            Toggle("Previous", isOn: $showPrevious)
                .help("Logs from the previous (crashed) container run")
        }
        .toggleStyle(.checkbox)
        .fixedSize()
    }

    private var filterField: some View {
        TextField("Filter", text: $filter, prompt: Text("Filter"))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 70, maxWidth: 150)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            streamer.clear()
        } label: {
            Label("Clear Logs", systemImage: "trash").labelStyle(.iconOnly)
        }
        .help("Clear")
        .disabled(streamer.lines.isEmpty)
        Button {
            Pasteboard.copy(streamer.lines.map(\.text).joined(separator: "\n"))
        } label: {
            Label("Copy All Logs", systemImage: "doc.on.doc").labelStyle(.iconOnly)
        }
        .help("Copy all")
        .disabled(streamer.lines.isEmpty)
        if allowsExpansion {
            Button {
                showExpanded = true
            } label: {
                Label("Expand Logs", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(.iconOnly)
            }
            .help("Open logs in a larger view")
        }
    }
}

/// Large resizable sheet for reading logs with more room than the inspector
/// column offers. Runs its own stream; the panel's stream resumes behind it.
private struct LogExpandedSheet: View {
    @Environment(\.dismiss) private var dismiss
    let object: KubeObject
    let kind: ResourceKind

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs — \(object.name)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            LogView(object: object, kind: kind, allowsExpansion: false)
        }
        .frame(
            minWidth: 900, idealWidth: 1080, maxWidth: .infinity,
            minHeight: 600, idealHeight: 760, maxHeight: .infinity
        )
        .background(SheetWindowConfigurator(minSize: CGSize(width: 900, height: 600)))
    }
}

/// Read-only NSTextView-backed log renderer: native multi-line selection,
/// ⌘F find bar, colored per-pod gutter tags, incremental appends.
private struct LogTextView: NSViewRepresentable {
    let lines: [LogStreamer.Line]
    let follow: Bool
    let wrap: Bool
    var onInteractiveScrollAway: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = Coordinator.font
        textView.textContainerInset = NSSize(width: 6, height: 6)
        context.coordinator.textView = textView
        context.coordinator.setWrapping(wrap)
        context.coordinator.observeUserScrolls(of: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onScrollAway = onInteractiveScrollAway
        context.coordinator.setWrapping(wrap)
        context.coordinator.render(lines: lines, follow: follow)
    }

    @MainActor
    final class Coordinator {
        static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        private static let palette: [NSColor] = [
            .systemCyan, .systemGreen, .systemOrange, .systemPurple,
            .systemPink, .systemTeal, .systemIndigo, .systemMint, .systemYellow,
        ]

        weak var textView: NSTextView?
        var onScrollAway: (() -> Void)?
        private var firstID: Int?
        private var lastID: Int?
        private var renderedCount = 0
        private var isWrapping: Bool?
        private var isFollowing = false
        private var scrollObserver: ObserverToken?

        /// Removes its notification observer when released — sidesteps
        /// Swift 6's ban on touching non-Sendable state in deinit.
        private final class ObserverToken: @unchecked Sendable {
            // nonisolated(unsafe): deinit runs once and removeObserver is
            // thread-safe; Swift 6 can't prove that for a non-Sendable token.
            private nonisolated(unsafe) let token: NSObjectProtocol
            init(_ token: NSObjectProtocol) { self.token = token }
            deinit { NotificationCenter.default.removeObserver(token) }
        }

        /// didLiveScroll fires only for user-initiated scrolling (wheel,
        /// trackpad, scroller drag) — never for our programmatic pinning —
        /// so it's the reliable "the user wants to read" signal.
        func observeUserScrolls(of scrollView: NSScrollView) {
            scrollObserver = ObserverToken(NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.userScrolled(scrollView)
                }
            })
        }

        private func userScrolled(_ scrollView: NSScrollView) {
            guard isFollowing, let textView else { return }
            let distanceFromBottom = textView.frame.height - scrollView.contentView.bounds.maxY
            if distanceFromBottom > 40 {
                isFollowing = false // render() resyncs from SwiftUI state
                onScrollAway?()
            }
        }

        func setWrapping(_ wrap: Bool) {
            guard wrap != isWrapping, let textView, let scrollView = textView.enclosingScrollView else { return }
            isWrapping = wrap
            let infinity = CGFloat.greatestFiniteMagnitude
            if wrap {
                scrollView.hasHorizontalScroller = false
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.textContainer?.widthTracksTextView = true
                textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: infinity)
                textView.frame.size.width = scrollView.contentSize.width
            } else {
                scrollView.hasHorizontalScroller = true
                textView.isHorizontallyResizable = true
                textView.minSize = .zero
                textView.maxSize = NSSize(width: infinity, height: infinity)
                // See YAMLEditor: autoresizing would clamp the frame back to
                // the clip view width, breaking horizontal scrolling.
                textView.autoresizingMask = []
                textView.textContainer?.widthTracksTextView = false
                textView.textContainer?.containerSize = NSSize(width: infinity, height: infinity)
                textView.sizeToFit()
            }
        }

        func render(lines: [LogStreamer.Line], follow: Bool) {
            isFollowing = follow
            guard let textView, let storage = textView.textStorage else { return }

            let isAppend = renderedCount > 0
                && lines.count >= renderedCount
                && lines.first?.id == firstID
                && lines[renderedCount - 1].id == lastID

            if isAppend {
                guard lines.count > renderedCount else { return }
                storage.beginEditing()
                for line in lines[renderedCount...] {
                    storage.append(Self.attributedLine(line.text))
                }
                storage.endEditing()
            } else {
                let all = NSMutableAttributedString()
                for line in lines {
                    all.append(Self.attributedLine(line.text))
                }
                storage.setAttributedString(all)
            }

            renderedCount = lines.count
            firstID = lines.first?.id
            lastID = lines.last?.id

            if follow {
                textView.scrollToEndOfDocument(nil)
            }
        }

        private static func attributedLine(_ raw: String) -> NSAttributedString {
            let parsed = LogLineParser.parse(raw)
            let result = NSMutableAttributedString()
            if let tag = parsed.tag {
                let podName = LogLineParser.podName(from: tag)
                let gutter = LogLineParser.shortSuffix(podName).padding(toLength: 6, withPad: " ", startingAt: 0)
                result.append(NSAttributedString(
                    string: gutter + "│ ",
                    attributes: [.foregroundColor: color(for: podName), .font: font]
                ))
            }
            if let timestamp = parsed.timestamp {
                result.append(NSAttributedString(
                    string: timestamp + " ",
                    attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: font]
                ))
            }
            result.append(NSAttributedString(
                string: parsed.message + "\n",
                attributes: [.foregroundColor: NSColor.labelColor, .font: font]
            ))
            return result
        }

        private static func color(for podName: String) -> NSColor {
            // Not abs(): abs(Int.min) traps, and the hash input is
            // cluster-controlled text.
            palette[Int(UInt(bitPattern: LogLineParser.stableHash(podName)) % UInt(palette.count))]
        }
    }
}
