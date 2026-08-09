import SwiftUI

/// "New <Kind>" sheet: a template manifest the user edits and applies.
struct CreateResourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: ResourceKind

    @State private var yaml: String
    @State private var applying = false
    @State private var errorMessage: String?

    init(kind: ResourceKind, namespace: String?) {
        self.kind = kind
        _yaml = State(initialValue: ResourceTemplates.template(for: kind, namespace: namespace ?? "default"))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New \(kind.kindName)")
                    .font(.headline)
                Spacer()
                Text("Created with kubectl apply")
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

            YAMLEditor(text: $yaml)
                .frame(minWidth: 640, minHeight: 440)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            HStack {
                if applying {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(applying || yaml.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func create() {
        applying = true
        errorMessage = nil
        Task {
            do {
                _ = try await model.applyYAML(yaml)
                applying = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                applying = false
            }
        }
    }
}
