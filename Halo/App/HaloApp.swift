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
                    // F-028: get hidden apps back on a clean quit. The persisted
                    // session covers crashes and force-quits; this covers ⌘Q,
                    // which is the common case and shouldn't wait for a relaunch.
                    FocusSessionManager.shared.observeAppTermination()
                    // F-028: resume a session a crash interrupted. Deliberately
                    // here and not in the manager's `init` — starting a session
                    // builds the overlay, and doing that from inside the
                    // singleton's own initializer deadlocked the launch on a
                    // reentrant `swift_once`. See `recoverInterruptedSession()`.
                    FocusSessionManager.shared.resumeInterruptedSession()
                    // F-021: resume app-usage tracking if the user has opted in
                    AppUsageTracker.shared.startIfEnabled()
                    // F-029: start weekly-digest scheduler (opt-in; no-op until enabled in Settings)
                    WeeklyDigestScheduler.shared.start(appState: appState)
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

/// Halo is a `WindowGroup` + `MenuBarExtra` app. Because a `MenuBarExtra` is
/// present, macOS can leave the app running with no main window on screen after
/// launch (or after window-state restoration returns "no windows"), so the user
/// sees only the menu-bar item and the sidebar is unreachable. This delegate
/// guarantees the main window is opened and brought forward on launch and on
/// re-open (Dock click / reactivation). Safe in normal use; also fixes headless
/// XCUITest launches.
final class HaloAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        surfaceMainWindow()
    }

    /// Reopen (Dock click, `open` again) should always reveal the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { surfaceMainWindow() }
        return true
    }

    /// Bring an existing content window forward, or ask AppKit to open one if
    /// the WindowGroup produced none.
    private func surfaceMainWindow() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                // No WindowGroup window exists — trigger the standard "new window".
                NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
