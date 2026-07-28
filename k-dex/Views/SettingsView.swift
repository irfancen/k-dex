import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKeys.kubectlPath) private var kubectlPath = ""
    @AppStorage(SettingsKeys.kubeconfigPath) private var kubeconfigPath = ""
    @AppStorage(SettingsKeys.extraPath) private var extraPath = ""
    @AppStorage(SettingsKeys.logTail) private var logTail = 500

    var body: some View {
        Form {
            Section {
                TextField("kubectl path", text: $kubectlPath, prompt: Text("auto-detect"))
                TextField("Kubeconfig path", text: $kubeconfigPath, prompt: Text("~/.kube/config"))
                TextField("Extra PATH entries", text: $extraPath, prompt: Text("/some/bin:/other/bin"))
            } header: {
                Text("kubectl")
            } footer: {
                Text("Extra PATH entries are prepended when running kubectl — useful for auth plugins like aws, gke-gcloud-auth-plugin, or kubelogin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Logs") {
                TextField("Initial lines to load", value: $logTail, format: .number)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
