import SwiftUI

@main
struct HaloMobileApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var cloud = CloudModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(cloud)
                .preferredColorScheme(.dark)
                .tint(.haloAccent)
                // iOS can't host a listener while suspended (requirements MR-OS-2): listen while
                // the app is active, stop cleanly when it is not.
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active: model.startServer(); cloud.startSync()
                    case .background: model.stopServer(); cloud.stopSync()
                    default: break
                    }
                }
                .onAppear { model.startServer(); cloud.startSync() }
                // App-switcher snapshots must not show message bodies or OTPs: cover the UI whenever not active.
                .overlay { if scenePhase != .active { PrivacyShield() } }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    @EnvironmentObject var cloud: CloudModel
    @State private var tab: Tab = .share
    enum Tab: Hashable { case share, inbox, messages, clipboard, settings }

    var body: some View {
        TabView(selection: $tab) {
            ShareView()
                .tabItem { Label("Share", systemImage: "arrow.up.arrow.down.circle") }.tag(Tab.share)
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray.and.arrow.down") }
                .badge(model.inbox.count).tag(Tab.inbox)
            MessagesView()
                .tabItem { Label(CloudStrings.messages, systemImage: "message") }.tag(Tab.messages)
            ClipboardView()
                .tabItem { Label(CloudStrings.clipboard, systemImage: "doc.on.clipboard") }.tag(Tab.clipboard)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
        }
        .background(Color.haloBackground.ignoresSafeArea())
        .onChange(of: cloud.wantsSetup) { want in if want { tab = .settings } }
        .sheet(item: $model.pendingOffer) { pending in
            ConsentSheet(offer: pending.offer)
                .interactiveDismissDisabled()      // declining must be an explicit act
        }
    }
}

/// Covers the UI while the app is inactive/backgrounded so the app-switcher snapshot shows nothing private.
struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Color.haloBackground.ignoresSafeArea()
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 44)).foregroundColor(.haloAccent.opacity(0.6))
        }
        .accessibilityHidden(true)
    }
}
