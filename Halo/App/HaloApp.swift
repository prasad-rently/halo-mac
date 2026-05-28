import SwiftUI

@main
struct HaloApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var menuBarManager = MenuBarManager()

    init() {
        // F-004: Load signature database from bundle, then check for delta update.
        Task {
            await SignatureDatabase.shared.load()
            await SignatureDatabase.shared.checkForUpdate()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(menuBarManager)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            HaloCommands()
        }

        // Menu Bar Extra
        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(appState)
                .environmentObject(menuBarManager)
        } label: {
            MenuBarIconView(state: menuBarManager.systemPressure)
        }
        .menuBarExtraStyle(.window)

        // Settings Window
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
