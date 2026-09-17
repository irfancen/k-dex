import SwiftUI

/// The sign-in sheet. Its job is to make the device code impossible to lose:
/// it stays on screen with the browser reopenable for the whole ten-minute
/// window, and says so plainly when that window closes.
struct AWSSignInSheet: View {
    @Bindable var model: AWSSignInModel
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sign in to AWS")
                .font(.headline)
            Text("\(model.target.cluster) · \(model.target.region)"
                 + (model.target.accountID.map { " · account \($0)" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text("AWS access portal URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://my-org.awsapps.com/start", text: $model.startURL)
                    .textFieldStyle(.roundedBorder)
                Text("K-Dex signs in directly — the AWS CLI is not used and does not need to be installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .registering:
            progress("Contacting AWS…")

        case .awaitingApproval(let auth):
            VStack(alignment: .leading, spacing: 12) {
                Text("Approve this sign-in in your browser, and check the code matches:")
                    .font(.callout)
                HStack {
                    Text(auth.userCode)
                        .font(.system(.title2, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") { model.copyCode() }
                    Button("Open Browser") { model.openBrowser() }
                }
                // The point of requirement 17: closing that window is free.
                Text("Closing the browser window is fine — reopen it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            }

        case .exchanging, .storing:
            progress("Finishing sign-in…")

        case .choosingRole(_, let roles):
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a role")
                    .font(.callout)
                ForEach(roles, id: \.self) { role in
                    Button(role) { model.chooseRole(role) }
                        .buttonStyle(.bordered)
                }
            }

        case .done:
            Label("Signed in. This cluster is ready.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .expired:
            VStack(alignment: .leading, spacing: 8) {
                Label("The sign-in request expired.", systemImage: "clock.badge.exclamationmark")
                Text("Codes are valid for about ten minutes. Start again when you're ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Sign-in failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch model.phase {
            case .done:
                Button("Done") { onFinished(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            case .expired, .failed:
                Button("Close") { dismiss() }
                // Requirement 18: expiry is recoverable, not a dead end.
                Button("Try Again") { model.cancel(); model.start() }
                    .keyboardShortcut(.defaultAction)
            case .idle:
                Button("Cancel") { dismiss() }
                Button("Sign In") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            default:
                Button("Cancel") { model.cancel(); dismiss() }
            }
        }
    }
}
