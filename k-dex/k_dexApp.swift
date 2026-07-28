import SwiftUI

@main
struct KDexApp: App {
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
