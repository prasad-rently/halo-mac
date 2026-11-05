import SwiftUI

@main
struct HaloMobileApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(.haloAccent)
                // iOS can't host a listener while suspended (requirements MR-OS-2): listen while
                // the app is active. Leaving mid-transfer asks iOS for a short grace period first
                // (D8); the model stops the listener once nothing is in flight.
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active: model.didBecomeActive()
                    case .background: model.didEnterBackground()
                    default: break
                    }
                }
                .onAppear { model.didBecomeActive() }
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

    var body: some View {
        TabView {
            ShareView()
                .tabItem { Label("Share", systemImage: "arrow.up.arrow.down.circle") }
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray.and.arrow.down") }
                .badge(model.inbox.count)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .background(Color.haloBackground.ignoresSafeArea())
        .sheet(item: $model.pendingOffer) { pending in
            ConsentSheet(offer: pending.offer)
                .interactiveDismissDisabled()      // declining must be an explicit act
        }
        .sheet(isPresented: $model.showSendSheet) {
            SendSheet().environmentObject(model)
        }
    }
}
