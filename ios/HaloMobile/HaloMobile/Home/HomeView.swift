import SwiftUI
import HaloShareKit

/// Home — the dashboard. Status ring, 2-up metric tiles, quick actions, recent activity. No paragraphs.
/// Cloud-backed tiles come from `HomeBridge` (see Integration/CloudIntegrationPoints.swift).
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var bridge: HomeBridge
    @EnvironmentObject var router: AppRouter
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HaloLayout.sectionSpacing) {
                    statusCard
                    metricGrid
                    if bridge.snapshot.isConfigured { cloudTiles } else { setupCloudCard }
                    quickActions
                    recentActivity
                }
                .padding(HaloLayout.screenPadding)
            }
            .haloScreen()
            .navigationTitle(HaloStrings.Home.title)
        }
    }

    // MARK: Status

    private struct Summary { var value: String; var caption: String; var progress: Double; var state: HaloState }

    private var summary: Summary {
        if case .error = bridge.snapshot.status {
            return Summary(value: HaloStrings.Home.ringProblem, caption: HaloStrings.Home.cloudService, progress: 0.2, state: .error)
        }
        if case .synced = bridge.snapshot.status, case .listening = model.listenState {
            return Summary(value: HaloStrings.Home.ringSynced, caption: HaloStrings.Home.cloudService, progress: 1, state: .ok)
        }
        switch model.listenState {
        case .listening: return Summary(value: HaloStrings.Home.ringReady, caption: HaloStrings.Home.shareService, progress: 1, state: .ok)
        case .starting: return Summary(value: HaloStrings.Home.ringStarting, caption: HaloStrings.Home.shareService, progress: 0.5, state: .warning)
        case .stopped, .failed: return Summary(value: HaloStrings.Home.ringOffline, caption: HaloStrings.Home.shareService, progress: 0.15, state: .error)
        }
    }

    private var statusCard: some View {
        let s = summary
        return HaloCard(accentTop: s.state.color, padding: 16) {
            HStack(spacing: 16) {
                HaloRing(progress: s.progress, tint: s.state.color, value: s.value, caption: s.caption, size: 112)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.identity.alias).font(HaloFont.title).foregroundColor(.haloText)
                        .lineLimit(2).minimumScaleFactor(0.8)
                    serviceRow(HaloStrings.Home.shareService, shareBadge)
                    cloudServiceRow
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("home.status")
    }

    private func serviceRow(_ name: String, _ badge: HaloStatusBadge) -> some View {
        HStack(spacing: 6) {
            Text(name).font(HaloFont.caption).foregroundColor(.haloText2)
            badge
        }
    }

    private var shareBadge: HaloStatusBadge {
        switch model.listenState {
        case .listening(let port): return HaloStatusBadge("Port \(port)", .ok)
        case .starting: return HaloStatusBadge("Starting", .warning)
        case .stopped: return HaloStatusBadge("Off", .error)
        case .failed: return HaloStatusBadge("Can't receive", .error)
        }
    }

    @ViewBuilder private var cloudServiceRow: some View {
        let status = bridge.snapshot.status
        let badge: HaloStatusBadge = {
            switch status {
            case .notSetUp: return HaloStatusBadge(HaloStrings.Settings.cloudNotSetUp, .neutral)
            case .connecting: return HaloStatusBadge("Connecting", .info)
            case .synced: return HaloStatusBadge(HaloStrings.Home.ringSynced, .ok)
            case .error: return HaloStatusBadge(HaloStrings.Home.ringProblem, .error)
            }
        }()
        if case .notSetUp = status {
            Button { HaloHaptics.tap(); router.tab = .settings } label: {
                serviceRow(HaloStrings.Home.cloudService, badge).frame(minHeight: HaloLayout.minTarget, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -12)
            .accessibilityLabel("\(HaloStrings.Home.cloudService), \(HaloStrings.Settings.cloudNotSetUp)")
            .accessibilityHint("Opens Settings")
        } else {
            serviceRow(HaloStrings.Home.cloudService, badge)
        }
    }

    // MARK: Metric tiles

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: HaloLayout.cardSpacing), GridItem(.flexible())]
    }

    private var metricGrid: some View {
        LazyVGrid(columns: columns, spacing: HaloLayout.cardSpacing) {
            HaloMetricTile(title: HaloStrings.Home.nearby, value: "\(model.peers.count)", unit: HaloStrings.Home.nearbyUnit,
                           icon: "dot.radiowaves.left.and.right", tint: .haloGreen) { router.openShareAndScan() }
                .accessibilityIdentifier("home.tile.nearby")
            HaloMetricTile(title: HaloStrings.Home.received, value: "\(model.inbox.count)", unit: HaloStrings.Home.receivedUnit,
                           icon: "tray.and.arrow.down.fill", tint: .haloAccent) { router.openInbox() }
                .accessibilityIdentifier("home.tile.received")
        }
    }

    /// Only shown once the cloud layer reports it is configured.
    private var cloudTiles: some View {
        LazyVGrid(columns: columns, spacing: HaloLayout.cardSpacing) {
            HaloMetricTile(title: HaloStrings.Home.messagesToday, value: bridge.snapshot.messagesToday.map(String.init) ?? "—",
                           icon: "message.fill", tint: .haloAccent)
            HaloMetricTile(title: HaloStrings.Home.clipboardItems, value: bridge.snapshot.clipboardItems.map(String.init) ?? "—",
                           icon: "doc.on.clipboard", tint: .haloPurple)
        }
        .accessibilityIdentifier("home.cloudTiles")
    }

    /// PLACEHOLDER until the cloud workstream reports a configured snapshot.
    private var setupCloudCard: some View {
        HaloCard {
            HStack(spacing: 12) {
                Image(systemName: "icloud")
                    .font(.system(.title3).weight(.semibold)).foregroundColor(.haloCyan)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.haloCyan.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HaloStrings.Home.setupCloudTitle).font(HaloFont.headline).foregroundColor(.haloText)
                    Text(HaloStrings.Home.setupCloudSubtitle).font(HaloFont.caption).foregroundColor(.haloText2)
                }
                Spacer(minLength: 8)
                HaloIconButton(icon: "chevron.right", label: HaloStrings.Home.setupCloudAction, tint: .haloAccent) { router.tab = .settings }
            }
        }
        .accessibilityIdentifier("home.setupCloud")
    }

    // MARK: Quick actions

    private var actions: [HomeQuickAction] {
        [
            HomeQuickAction(id: "scan", title: HaloStrings.Home.scanNearby, icon: "dot.radiowaves.left.and.right", tint: .haloGreen) { router.openShareAndScan() },
            HomeQuickAction(id: "send", title: HaloStrings.Home.chooseFiles, icon: "doc.badge.plus", tint: .haloAccent) { router.tab = .share },
            HomeQuickAction(id: "inbox", title: HaloStrings.Home.openInbox, icon: "tray.and.arrow.down.fill", tint: .haloCyan) { router.openInbox() },
        ] + bridge.extraQuickActions
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(HaloStrings.Home.quickActions)
            let list = actions
            // Up to four fit side by side; beyond that (cloud adds more) the row scrolls.
            if list.count <= 4 && !typeSize.isAccessibilitySize {
                HStack(spacing: HaloLayout.cardSpacing) { ForEach(list) { quickTile($0, flexible: true) } }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HaloLayout.cardSpacing) { ForEach(list) { quickTile($0, flexible: false) } }
                        .padding(.horizontal, HaloLayout.screenPadding)
                }
                .padding(.horizontal, -HaloLayout.screenPadding)
            }
        }
    }

    private func quickTile(_ a: HomeQuickAction, flexible: Bool) -> some View {
        Button { HaloHaptics.tap(); a.action() } label: {
            VStack(spacing: 8) {
                Image(systemName: a.icon).font(.system(.title3).weight(.medium)).foregroundColor(a.tint)
                Text(a.title).font(HaloFont.caption.weight(.semibold)).foregroundColor(.haloText)
                    .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 14).padding(.horizontal, 6)
            .frame(maxWidth: flexible ? .infinity : 104, minHeight: 88)
            .frame(width: flexible ? nil : 104)
            .background(Color.haloSurface2)
            .clipShape(RoundedRectangle(cornerRadius: HaloLayout.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HaloLayout.cardRadius, style: .continuous).stroke(Color.haloBorder, lineWidth: 1))
        }
        .buttonStyle(HaloPressStyle())
        .accessibilityIdentifier("home.action.\(a.id)")
    }

    // MARK: Recent activity

    /// Bridge activity (last transfer, cloud events) merged with the newest received files.
    private var activityRows: [HomeActivity] {
        let received = model.inbox.prefix(5).map {
            HomeActivity(id: $0.id, icon: "arrow.down.circle.fill", tint: .haloGreen,
                         title: "Received \($0.name)", date: $0.date)
        }
        return (bridge.activity + received).sorted { $0.date > $1.date }.prefix(5).map { $0 }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(HaloStrings.Home.recentActivity)
            let rows = activityRows
            if rows.isEmpty {
                HaloCard {
                    HaloEmptyState(icon: "clock", title: HaloStrings.Home.noActivity, subtitle: HaloStrings.Home.noActivityHint,
                                   actionTitle: HaloStrings.Home.scanNearby) { router.openShareAndScan() }
                }
            } else {
                HaloCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { HaloRowDivider() }
                            HaloListRow(icon: row.icon, tint: row.tint, title: row.title) {
                                Text(HaloTime.relative(row.date)).font(HaloFont.caption).foregroundColor(.haloText2)
                                    .lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
                .accessibilityIdentifier("home.activity")
            }
        }
    }
}
