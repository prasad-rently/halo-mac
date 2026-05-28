import SwiftUI
import Sentry

@main
struct HaloApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var menuBarManager = MenuBarManager()

    init() {
        // F-006: Sentry crash reporting — opt-in only, no PII.
        HaloApp.configureSentry()

        // F-004: Load signature database from bundle, then check for delta update.
        Task {
            await SignatureDatabase.shared.load()
            await SignatureDatabase.shared.checkForUpdate()
        }
    }

    // MARK: - Sentry (F-006)

    private static func configureSentry() {
        // Respect user's analytics opt-in (defaults to false = off).
        let analyticsEnabled = UserDefaults.standard.bool(forKey: "enableAnalytics")
        guard analyticsEnabled else { return }

        // Require a real DSN — skip the placeholder so debug builds are silent.
        guard let dsn = Bundle.main.infoDictionary?["SentryDSN"] as? String,
              !dsn.isEmpty,
              dsn != "SENTRY_DSN_PLACEHOLDER" else { return }

        guard let sentryEnabled = Bundle.main.infoDictionary?["SentryEnabled"] as? Bool,
              sentryEnabled else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            // Privacy: never attach personally identifiable info
            options.sendDefaultPii = false
            // Diagnostics
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            options.sessionTrackingIntervalMillis = 30_000
            // Environment tagging
            #if DEBUG
            options.environment = "debug"
            options.sampleRate = 0.0   // silence debug builds
            #else
            options.environment = "release"
            options.sampleRate = 1.0
            options.tracesSampleRate = 0.1   // 10% performance traces
            #endif
        }
    }



    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(menuBarManager)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    // F-005: start background scan scheduler now that AppState is ready
                    ScanScheduler.shared.start(appState: appState)
                }
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
            // F-008: pass live CPU/RAM for text-stats and mini-bar display styles
            MenuBarIconView(
                state: menuBarManager.systemPressure,
                cpuUsage: menuBarManager.cpuUsage,
                ramUsage: menuBarManager.ramUsage
            )
        }
        .menuBarExtraStyle(.window)

        // Settings Window
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
