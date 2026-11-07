import SwiftUI

// MARK: - Integration points for the cloud features (Messages / Clipboard / pairing)
//
// The design workstream owns the *shell* (Home, Share, Settings, tab bar). The cloud workstream
// owns the logic. Everything it needs to plug in is in this file — nothing here talks to a
// network or a store.
//
//  1. Add your tab: add a case to `AppTab`, add a tab to `RootView`'s TabView (HaloMobileApp.swift).
//  2. Publish status to Home:     `bridge.snapshot = HomeCloudSnapshot(...)`.
//  3. Add Home quick actions:     `bridge.extraQuickActions = [HomeQuickAction(...)]`.
//  4. Add Home recent activity:   `bridge.record(HomeActivity(...))`.
//  5. Replace the body of `CloudSettingsSection` with the real setup stepper / pairing UI.
//  6. Open a screen from Home:    `router.tab = .messages` (after adding the case).

/// Tabs, in tab-bar order. Raw value is the stable identifier used in `accessibilityIdentifier`s.
enum AppTab: String, CaseIterable, Hashable {
    case home, messages, clipboard, share, settings
}

/// Cross-tab navigation. Home's tiles and quick actions drive this; views never reach into each other.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .home
    /// Share's NavigationStack pushes the full inbox when this flips true.
    @Published var showInbox = false
    /// Share starts a Wi-Fi scan when it appears with this set.
    @Published var scanOnShare = false

    /// Opens the send sheet for whatever is waiting in the outbox (Share Extension / pickers).
    /// The router only switches to Share; the sheet itself is driven by `AppModel.showSendSheet`.
    func openShare() { tab = .share }
    func openInbox() { showInbox = true; tab = .share }
    func openShareAndScan() { scanOnShare = true; tab = .share }
}

enum HomeCloudStatus: Equatable {
    case notSetUp
    case connecting
    case synced(Date)
    case error(String)
}

/// What Home needs to know about the cloud layer. `nil` counts mean "not available yet" and render as "—".
struct HomeCloudSnapshot: Equatable {
    var status: HomeCloudStatus = .notSetUp
    var messagesToday: Int?
    var clipboardItems: Int?
    var lastSync: Date?

    static let notSetUp = HomeCloudSnapshot()
    var isConfigured: Bool { if case .notSetUp = status { return false } else { return true } }
}

struct HomeQuickAction: Identifiable {
    let id: String
    var title: String
    var icon: String
    var tint: Color = .haloAccent
    var action: () -> Void
}

struct HomeActivity: Identifiable, Equatable {
    let id: String
    var icon: String
    var tint: Color
    var title: String
    var date: Date

    init(id: String = UUID().uuidString, icon: String, tint: Color, title: String, date: Date = Date()) {
        self.id = id; self.icon = icon; self.tint = tint; self.title = title; self.date = date
    }
}

/// Items lined up to send but not sent yet (Share Extension / file picker / photo picker).
/// Only counts and bytes cross this boundary — never file names.
struct HomePendingShare: Equatable {
    var itemCount: Int
    var totalBytes: Int64
    /// Further staged batches waiting behind the one in the outbox.
    var moreBatches: Int
}

/// The one object the cloud workstream writes to and Home reads from.
@MainActor
final class HomeBridge: ObservableObject {
    @Published var snapshot: HomeCloudSnapshot = .notSetUp
    @Published var pendingShare: HomePendingShare?
    @Published var extraQuickActions: [HomeQuickAction] = []
    @Published private(set) var activity: [HomeActivity] = []

    /// Newest first, capped — Home shows 3–5 rows.
    func record(_ item: HomeActivity) {
        activity.insert(item, at: 0)
        if activity.count > 20 { activity.removeLast(activity.count - 20) }
    }
}

/// Settings → Cloud row. Opens the pairing / database-check screen (`CloudSetupView`) via `openSetup`.
/// Long explanations (viewer-only on iPhone, manual clipboard) live behind the (i) sheet.
struct CloudSettingsSection: View {
    @EnvironmentObject var cloud: CloudModel
    var openSetup: () -> Void
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(HaloStrings.Settings.cloud, onInfo: { showInfo = true })
            Button { HaloHaptics.tap(); openSetup() } label: {
                HaloCard(padding: 0) {
                    HaloListRow(icon: cloud.isPaired ? "icloud.fill" : "icloud", tint: .haloCyan,
                                title: HaloStrings.Settings.cloudRowTitle,
                                subtitle: HaloStrings.Settings.cloudRowSubtitle, showsChevron: true) {
                        HaloStatusBadge(cloud.isPaired ? "Paired" : HaloStrings.Settings.cloudNotSetUp, cloud.isPaired ? .ok : .neutral)
                    }
                }
            }
            .buttonStyle(HaloPressStyle())
            .accessibilityIdentifier("settings.cloud")
        }
        .haloInfoSheet(isPresented: $showInfo, title: HaloStrings.Info.cloudTitle, points: [
            HaloInfoPoint("message", .haloAmber, HaloStrings.Settings.viewerOnly,
                          "iOS gives apps no access to your text messages, so Halo shows messages synced from an Android phone but can't read this iPhone's."),
            HaloInfoPoint("doc.on.clipboard", .haloPurple, "Clipboard is manual",
                          "iOS only lets an app read the clipboard while it is open, so you send it yourself — nothing syncs in the background."),
        ])
    }
}
