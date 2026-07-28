import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "helm")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("Try Again") { model.retryBootstrap() }
                    .keyboardShortcut(.defaultAction)
                SettingsLink {
                    Text("Open Settings…")
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch model.bootState {
        case .missingKubectl: return "kubectl Not Found"
        case .noContexts: return "No Clusters Found"
        case .failed: return "Couldn't Load Contexts"
        default: return ""
        }
    }

    private var message: String {
        switch model.bootState {
        case .missingKubectl:
            return "K-Dex uses your local kubectl to talk to clusters. Install it (e.g. `brew install kubectl`) or point K-Dex at the binary in Settings."
        case .noContexts:
            return "Your kubeconfig (~/.kube/config) has no contexts. Add a cluster with your cloud CLI or copy a kubeconfig, then try again. A custom kubeconfig path can be set in Settings."
        case .failed(let error):
            return error
        default:
            return ""
        }
    }
}
