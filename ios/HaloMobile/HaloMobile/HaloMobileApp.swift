import SwiftUI

@main
struct HaloMobileApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var cloud = CloudModel()
    @StateObject private var router = AppRouter()
    @StateObject private var bridge = HomeBridge()
    @Environment(\.scenePhase) private var scenePhase

    init() { HaloAppearance.install() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(cloud)
                .environmentObject(router)
                .environmentObject(bridge)
                .preferredColorScheme(.dark)
                .tint(.haloAccent)
                // iOS can't host a listener while suspended (requirements MR-OS-2): listen while
                // the app is active. Leaving mid-transfer asks iOS for a short grace period first
                // (D8); the model stops the listener once nothing is in flight.
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active: model.didBecomeActive(); cloud.startSync()
                    case .background: model.didEnterBackground(); cloud.stopSync()
                    default: break
                    }
                }
                // App-switcher snapshots must not show message bodies, OTPs or file names: cover the UI whenever not active.
                .overlay { if scenePhase != .active { PrivacyShield() } }
                .onAppear {
                    model.didBecomeActive(); cloud.startSync()
                    #if DEBUG
                    DebugLaunch.apply(model: model, router: router)
                    #endif
                }
                // halomobile://share (the Share Extension's "Open Halo"). The URL carries no data —
                // the staged items are read from the App Group container, never from the URL.
                .onOpenURL { url in
                    if url.scheme == "halomobile", url.host == "share" { model.loadStagedShares() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var bridge: HomeBridge
    @EnvironmentObject var cloud: CloudModel

    var body: some View {
        // Tab order: Home · (cloud: Messages · Clipboard) · Share · Settings. See Integration/CloudIntegrationPoints.swift.
        TabView(selection: $router.tab) {
            HomeView()
                .tabItem { Label(HaloStrings.Tab.home, systemImage: "house.fill") }
                .tag(AppTab.home)
            MessagesView()
                .tabItem { Label(CloudStrings.messages, systemImage: "message.fill") }
                .tag(AppTab.messages)
            ClipboardView()
                .tabItem { Label(CloudStrings.clipboard, systemImage: "doc.on.clipboard.fill") }
                .tag(AppTab.clipboard)
            ShareView()
                .tabItem { Label(HaloStrings.Tab.share, systemImage: "arrow.up.arrow.down.circle.fill") }
                .badge(model.unreadInboxCount)
                .tag(AppTab.share)
            SettingsView()
                .tabItem { Label(HaloStrings.Tab.settings, systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .background(Color.haloBackground.ignoresSafeArea())
        .sheet(item: $model.pendingOffer) { pending in
            ConsentSheet(offer: pending.offer)
                .interactiveDismissDisabled()      // declining must be an explicit act
        }
        // Not-yet-sent items (Share Extension / pickers) wait in the outbox; the send sheet is reachable from every tab.
        .sheet(isPresented: $model.showSendSheet) {
            SendSheet().environmentObject(model).environmentObject(router)
        }
        // Empty states in Messages/Clipboard ask for Settings → Cloud.
        .onChange(of: cloud.wantsSetup) { want in if want { router.tab = .settings } }
        // Cloud → Home dashboard (status ring, tiles, quick actions, activity).
        .modifier(CloudHomeBridge())
        // Items waiting to be sent (Share Extension / pickers) → Home banner + quick action.
        .modifier(ShareHomeBridge())
        // Last transfer → Home's Recent activity.
        .onChange(of: model.transfer) { state in
            switch state {
            case .finished(let message):
                bridge.record(HomeActivity(icon: "paperplane.fill", tint: .haloAccent, title: message))
            case .failed(let why):
                bridge.record(HomeActivity(icon: "exclamationmark.triangle.fill", tint: .haloRed, title: why))
            default: break
            }
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
