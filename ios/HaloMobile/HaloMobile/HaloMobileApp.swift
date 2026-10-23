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
                // the app is active, stop cleanly when it is not.
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active: model.startServer()
                    case .background: model.stopServer()
                    default: break
                    }
                }
                .onAppear { model.startServer() }
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
    }
}
