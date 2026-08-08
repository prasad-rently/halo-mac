import SwiftUI
import Sentry

@main
struct HaloApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var menuBarManager = MenuBarManager()
    // Under UI testing, this delegate forces the main window to open + activate
    // so XCUITest can drive the sidebar (Halo is a WindowGroup + MenuBarExtra app,
    // and the window doesn't reliably appear on a headless test launch).
    @NSApplicationDelegateAdaptor(HaloAppDelegate.self) private var appDelegate

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
                    // F-042: expose shared reference for App Intents
                    AppState.shared = appState
                    // F-005: start background scan scheduler now that AppState is ready
                    ScanScheduler.shared.start(appState: appState)
                }
                // F-041: handle halo:// deep links for action sharing
                .onOpenURL { url in
                    ActionShareManager.shared.handleURL(url)
                }
                .sheet(isPresented: Binding(
                    get: { ActionShareManager.shared.showImportSheet },
                    set: { ActionShareManager.shared.showImportSheet = $0 }
                )) {
                    ActionImportSheet(shareManager: ActionShareManager.shared)
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
            // F-036: pass all token values for custom format string rendering
            MenuBarIconView(
                state: menuBarManager.systemPressure,
                cpuUsage: menuBarManager.cpuUsage,
                ramUsage: menuBarManager.ramUsage,
                tokenValues: menuBarManager.tokenValues
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

// MARK: - App Delegate (UI-test window hook)

/// Only does anything when the app is launched with `-uiTesting` (set by
/// `HaloUITestCase`). Halo is a `WindowGroup` + `MenuBarExtra` app; on a headless
/// XCUITest launch the main window may not open or come forward on its own, which
/// leaves the sidebar unreachable. Under the test flag this forces a normal,
/// activated app with a visible main window. In normal use it is a no-op.
final class HaloAppDelegate: NSObject, NSApplicationDelegate {
    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTesting")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isUITesting else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Bring a window forward once the run loop settles; if the WindowGroup
        // hasn't produced one, ask AppKit to open a fresh document/window.
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Clicking the Dock / reopening should always surface the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }
}
