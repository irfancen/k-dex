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
    @State private var filter = ""
    @State private var showExpanded = false
    @AppStorage(SettingsKeys.logTail) private var tail = 500

    init(object: KubeObject, kind: ResourceKind, allowsExpansion: Bool = true) {
        self.object = object
        self.kind = kind
        self.allowsExpansion = allowsExpansion
        let containers = kind == .pods
            ? object.raw["spec"]["containers"].array.map { $0["name"].stringValue }
            : []
        _container = State(initialValue: containers.first ?? "")
    }

    private var isAggregate: Bool { kind != .pods }
    private var selector: String? { isAggregate ? KindHelpers.podSelectorString(object) : nil }

    private var containers: [String] {
        guard kind == .pods else { return [] }
        return (object.raw["spec"]["containers"].array + object.raw["spec"]["initContainers"].array)
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
                LogTextView(lines: visibleLines, follow: follow, wrap: wrapLines)
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
            .task(id: "\(object.id)/\(container)/\(follow)/\(showTimestamps)") {
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
            target = .selector(selector)
        } else {
            target = .pod(name: object.name, container: container.isEmpty ? nil : container)
        }
        streamer.start(
            context: model.selectedContext,
            namespace: object.namespace,
            target: target,
            follow: follow,
            tail: max(tail, 10),
            timestamps: showTimestamps
        )
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if containers.count > 1 {
                Picker("Container", selection: $container) {
                    ForEach(containers, id: \.self) { Text($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
            Toggle("Time", isOn: $showTimestamps)
                .toggleStyle(.checkbox)
                .help("Show timestamps")
            Toggle("Wrap", isOn: $wrapLines)
                .toggleStyle(.checkbox)
                .help("Wrap long lines")
            TextField("Filter", text: $filter, prompt: Text("Filter"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 150)
            Spacer()
            Button {
                streamer.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear")
            .disabled(streamer.lines.isEmpty)
            Button {
                Pasteboard.copy(streamer.lines.map(\.text).joined(separator: "\n"))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy all")
            .disabled(streamer.lines.isEmpty)
            if allowsExpansion {
                Button {
                    showExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Open logs in a larger view")
            }
        }
        .controlSize(.small)
        .padding(8)
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
        .background(SheetWindowConfigurator())
    }
}

/// Read-only NSTextView-backed log renderer: native multi-line selection,
/// ⌘F find bar, colored per-pod gutter tags, incremental appends.
private struct LogTextView: NSViewRepresentable {
    let lines: [LogStreamer.Line]
    let follow: Bool
    let wrap: Bool

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
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
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
        private var firstID: Int?
        private var lastID: Int?
        private var renderedCount = 0
        private var isWrapping: Bool?

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

/// Splits `[pod/web-abc/nginx] 2026-07-24T09:12:33.1Z message` into parts.
nonisolated enum LogLineParser {
    struct Parsed {
        var tag: String?
        var timestamp: String?
        var message: String
    }

    static func parse(_ raw: String) -> Parsed {
        var rest = Substring(raw)
        var tag: String?
        if rest.first == "[", let close = rest.firstIndex(of: "]") {
            tag = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
            if rest.first == " " { rest = rest.dropFirst() }
        }
        var timestamp: String?
        if let space = rest.firstIndex(of: " ") {
            let candidate = rest[rest.startIndex..<space]
            if candidate.count >= 19, candidate.first?.isNumber == true,
               let tIndex = candidate.firstIndex(of: "T") {
                timestamp = String(candidate[candidate.index(after: tIndex)...].prefix(8))
                rest = rest[rest.index(after: space)...]
            }
        }
        return Parsed(tag: tag, timestamp: timestamp, message: String(rest))
    }

    /// "pod/web-7d4b9-abc12/nginx" → "web-7d4b9-abc12"
    static func podName(from tag: String) -> String {
        let parts = tag.split(separator: "/")
        return parts.count >= 2 ? String(parts[1]) : tag
    }

    /// "web-7d4b9-abc12" → "abc12" (the replica-unique suffix).
    static func shortSuffix(_ podName: String) -> String {
        if let dash = podName.lastIndex(of: "-"), dash != podName.startIndex {
            let suffix = podName[podName.index(after: dash)...]
            if !suffix.isEmpty { return String(suffix) }
        }
        return String(podName.prefix(6))
    }

    static func stableHash(_ text: String) -> Int {
        var hash = 5381
        for scalar in text.unicodeScalars {
            hash = (hash << 5) &+ hash &+ Int(scalar.value)
        }
        return hash
    }
}
