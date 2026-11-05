import SwiftUI
import HaloCloudKit

/// Publishes the cloud layer's state into Home's `HomeBridge` (see Integration/CloudIntegrationPoints.swift).
/// Only counts and timestamps cross this boundary — never message bodies or clipboard text.
struct CloudHomeBridge: ViewModifier {
    @EnvironmentObject var cloud: CloudModel
    @EnvironmentObject var bridge: HomeBridge
    @EnvironmentObject var router: AppRouter

    func body(content: Content) -> some View {
        content
            .onAppear { publish() }
            .onReceive(cloud.objectWillChange.debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)) { _ in publish() }
    }

    private func publish() {
        guard cloud.isPaired else {
            bridge.snapshot = .notSetUp
            bridge.extraQuickActions = []
            return
        }
        let status: HomeCloudStatus
        if let e = cloud.error { status = .error(e) }
        else if cloud.sms.connection == .live { status = .synced(Date()) }
        else { status = .connecting }
        let today = Calendar.current.startOfDay(for: Date())
        let messagesToday = cloud.sms.messages.values.filter { $0.date >= today }.count
        let latestClip = (cloud.remoteClips.map(\.createdAt) + cloud.sentClips.map(\.date)).max()
        bridge.snapshot = HomeCloudSnapshot(status: status, messagesToday: messagesToday,
                                            clipboardItems: cloud.remoteClips.count + cloud.sentClips.count,
                                            lastSync: latestClip)
        bridge.extraQuickActions = [
            HomeQuickAction(id: "messages", title: CloudStrings.messages, icon: "message.fill", tint: .haloAccent) { router.tab = .messages },
            HomeQuickAction(id: "clipboard", title: CloudStrings.clipboard, icon: "doc.on.clipboard", tint: .haloPurple) { router.tab = .clipboard },
        ]
    }
}
