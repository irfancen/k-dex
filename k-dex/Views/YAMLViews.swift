import SwiftUI

enum YAMLHighlighter {
    /// The key name when a line declares a zero-indentation mapping key.
    nonisolated static func topLevelKey(of line: String) -> String? {
        guard let first = line.first, first != " ", first != "-", first != "#" else { return nil }
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIndex])
        guard !key.isEmpty, !key.contains("\""), !key.contains("#") else { return nil }
        return key
    }

}

nonisolated enum ManifestCleaner {
    /// Prepares fetched YAML for editing: strips the server-managed `status:`
    /// block and volatile metadata (resourceVersion, uid, generation,
    /// creationTimestamp) so `kubectl apply` doesn't hit stale-version
    /// conflicts or complain about server-populated fields.
    static func editable(_ yaml: String) -> String {
        var kept: [Substring] = []
        var topLevelKey: String?
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let key = YAMLHighlighter.topLevelKey(of: text) {
                topLevelKey = key
            } else if text.trimmingCharacters(in: .whitespaces) == "---" {
                topLevelKey = nil
            }
            if topLevelKey == "status" { continue }
            if topLevelKey == "metadata", text.hasPrefix("  "), !text.hasPrefix("   ") {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("resourceVersion:")
                    || trimmed.hasPrefix("uid:")
                    || trimmed.hasPrefix("generation:")
                    || trimmed.hasPrefix("creationTimestamp:") {
                    continue
                }
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}

/// Large resizable editor sheet for working on a manifest with more room
/// than the inspector column offers.
struct YAMLExpandedEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let apply: (String) async throws -> String
    var onApplied: ((String) -> Void)?

    @State private var text: String
    @State private var applying = false
    @State private var errorMessage: String?

    init(title: String, initialText: String, apply: @escaping (String) async throws -> String, onApplied: ((String) -> Void)? = nil) {
        self.title = title
        self.apply = apply
        self.onApplied = onApplied
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("Applied with kubectl apply")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            YAMLEditor(text: $text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            HStack {
                if applying {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(applying ? "Applying…" : "Apply") { runApply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(applying || text.isEmpty)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Apply changes (⌘S)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(
            minWidth: 860, idealWidth: 1040, maxWidth: .infinity,
            minHeight: 600, idealHeight: 760, maxHeight: .infinity
        )
        .background(SheetWindowConfigurator())
    }

    private func runApply() {
        applying = true
        errorMessage = nil
        let edited = text
        Task {
            do {
                let message = try await apply(edited)
                applying = false
                dismiss()
                onApplied?(message)
            } catch {
                errorMessage = error.localizedDescription
                applying = false
            }
        }
    }
}

/// Read-only monospaced YAML/text display with highlighting. Backed by the
/// same NSTextView engine as the editor: identical colors, multi-line
/// selection, ⌘F find bar, and no SwiftUI two-axis-scroll layout quirks.
struct YAMLTextView: View {
    let text: String

    var body: some View {
        YAMLEditor(text: .constant(text), isEditable: false)
    }
}

