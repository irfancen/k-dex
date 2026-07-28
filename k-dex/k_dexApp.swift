import AppKit
import SwiftUI

/// Scene-independent termination hook: `willTerminateNotification` observers
/// attached to a window scene are skipped when the user closes all windows
/// and then quits, and view-scoped streamers are unreachable by then. The
/// reaper knows every long-lived child (logs, watches, port forwards).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ProcessReaper.shared.terminateAll()
    }
}

@main
struct KDexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var portForwards = PortForwardManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(portForwards)
                .frame(minWidth: 980, minHeight: 580)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.requestRefresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
