import SwiftUI

/// "New <Kind>" sheet: a template manifest the user edits and applies.
struct CreateResourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: ResourceKind

    @State private var yaml: String
    @State private var applying = false
    @State private var errorMessage: String?
    /// True while a custom kind's CRD schema is being read — the editor is
    /// held back so the template doesn't visibly morph from stub to
    /// generated mid-edit.
    @State private var loadingTemplate: Bool
    /// Both schema-derived variants, once the CRD is read. The toggle swaps
    /// between them only while the text is still one of the two — editing
    /// locks the choice so a switch can never discard typed work.
    @State private var templates: (simplified: String, complete: String)?
    @State private var detail: CRDTemplate.Detail = .simplified
    private let namespace: String
    private let stubTemplate: String

    init(kind: ResourceKind, namespace: String?) {
        self.kind = kind
        self.namespace = namespace ?? "default"
        self.stubTemplate = ResourceTemplates.template(for: kind, namespace: self.namespace)
        _yaml = State(initialValue: stubTemplate)
        _loadingTemplate = State(initialValue: kind.isCustom)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New \(kind.kindName)")
                    .font(.headline)
                Spacer()
                if let templates, templates.simplified != templates.complete {
                    Picker("Template detail", selection: $detail) {
                        Text("Simplified").tag(CRDTemplate.Detail.simplified)
                        Text("Complete").tag(CRDTemplate.Detail.complete)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!isUneditedTemplate)
                    .help(isUneditedTemplate
                        ? "Simplified collapses optional sections; Complete expands every schema field"
                        : "Editing locks the template choice")
                }
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

            // 592 + 2×24 padding = the window's 640 floor, so the editor and
            // window minimums agree and text keeps a comfortable margin even
            // fully shrunk (the sheet also opens at this minimum).
            if loadingTemplate {
                ProgressView("Reading the CRD schema…")
                    .controlSize(.small)
                    .frame(minWidth: 592, minHeight: 440)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            } else {
                YAMLEditor(text: $yaml)
                    .frame(minWidth: 592, minHeight: 440)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }

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
        // SwiftUI sheets don't get a resizable style mask on macOS even with
        // flexible content — same fix as the expanded editor/log sheets.
        // Min matches the editor's 640×440 plus header and footer chrome.
        .background(SheetWindowConfigurator(minSize: CGSize(width: 640, height: 560)))
        // CRD-backed kinds get a schema-derived template: required fields,
        // defaults, and placeholders synthesized from the CRD's own OpenAPI
        // schema. Any failure (fetch, no spec schema) silently keeps the
        // generic stub.
        .task {
            guard kind.isCustom else { return }
            defer { loadingTemplate = false }
            guard let crd = try? await Kubectl.crdDefinition(id: kind.id, context: model.selectedContext),
                  let simplified = CRDTemplate.generate(fromCRD: crd, kind: kind, namespace: namespace, detail: .simplified),
                  let complete = CRDTemplate.generate(fromCRD: crd, kind: kind, namespace: namespace, detail: .complete)
            else { return }
            templates = (simplified, complete)
            if yaml == stubTemplate { yaml = simplified }
        }
        .onChange(of: detail) {
            guard let templates, isUneditedTemplate else { return }
            yaml = detail == .simplified ? templates.simplified : templates.complete
        }
    }

    /// True while the editor still holds one of the generated variants (or
    /// the stub) untouched — the only states a template swap may replace.
    private var isUneditedTemplate: Bool {
        guard let templates else { return yaml == stubTemplate }
        return yaml == templates.simplified || yaml == templates.complete || yaml == stubTemplate
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
