import AppKit
import Foundation

/// The open panel that turns "the sandbox forbids this" into a grant.
///
/// Directories only. A sandboxed app receives access to exactly what the user
/// picked, so picking `config` would grant the file and not the folder — and
/// the next `minikube start`, which rewrites the client certificate, would
/// strand us again. See `SandboxGrants`.
@MainActor
enum GrantPanel {
    /// Asks for one directory, pre-pointed at the one we need so the user
    /// usually only has to confirm.
    ///
    /// - Returns: true when a grant was recorded.
    @discardableResult
    static func requestAccess(to directory: URL, explanation: String) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // Hidden by default, and every path we ask for begins with a dot.
        panel.showsHiddenFiles = true
        panel.directoryURL = directory
        panel.message = explanation
        panel.prompt = "Grant Access"
        panel.title = "Allow K-Dex to read \(directory.lastPathComponent)"

        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        do {
            try SandboxGrants.record(chosen)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }
}
