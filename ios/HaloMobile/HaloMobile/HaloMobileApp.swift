import SwiftUI

@main
struct HaloMobileApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var router = AppRouter()
    @StateObject private var bridge = HomeBridge()
    @Environment(\.scenePhase) private var scenePhase

    init() { HaloAppearance.install() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(router)
                .environmentObject(bridge)
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
                .onAppear {
                    model.startServer()
                    #if DEBUG
                    DebugLaunch.apply(model: model, router: router)
                    #endif
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var bridge: HomeBridge

    var body: some View {
        // Tab order: Home · (cloud: Messages · Clipboard) · Share · Settings. See Integration/CloudIntegrationPoints.swift.
        TabView(selection: $router.tab) {
            HomeView()
                .tabItem { Label(HaloStrings.Tab.home, systemImage: "house.fill") }
                .tag(AppTab.home)
            ShareView()
                .tabItem { Label(HaloStrings.Tab.share, systemImage: "arrow.up.arrow.down.circle.fill") }
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
