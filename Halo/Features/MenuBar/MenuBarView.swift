import SwiftUI
import AppKit

// MARK: - Menu Bar Manager

@MainActor
final class MenuBarManager: ObservableObject {
    @Published var systemPressure: SystemPressureLevel = .normal
    @Published var cpuUsage: Double = 0
    @Published var ramUsage: Double = 0
    @Published var diskFreeGB: Double = 0
    @Published var networkUpMBps: Double = 0
    @Published var networkDownMBps: Double = 0
    @Published var batteryPercent: Int = 100
    @Published var batteryTimeRemaining: String = ""

    enum SystemPressureLevel {
        case normal, moderate, critical
        var color: Color {
            switch self {
            case .normal: return .haloGreen
            case .moderate: return .haloAmber
            case .critical: return .haloRed
            }
        }
    }

    func update(from appState: AppState) {
        cpuUsage = appState.cpuUsage
        ramUsage = appState.ramUsage
        diskFreeGB = appState.diskFreeGB
        networkUpMBps = appState.networkUpMBps
        networkDownMBps = appState.networkDownMBps
        batteryPercent = appState.batteryPercent
        batteryTimeRemaining = appState.batteryTimeRemaining

        if cpuUsage > 0.85 || ramUsage > 0.90 {
            systemPressure = .critical
        } else if cpuUsage > 0.60 || ramUsage > 0.75 {
            systemPressure = .moderate
        } else {
            systemPressure = .normal
        }
    }
}

// MARK: - Menu Bar Display Style (F-008)

/// Controls how the menu-bar status item looks.
enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    case icon      = "icon"       // Halo icon + pressure glow (default)
    case textStats = "textStats"  // "47% · 68%" compact text
    case miniBar   = "miniBar"    // Tiny CPU/RAM progress bars
    case dot       = "dot"        // Solid colored pressure dot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .icon:      return "Halo Icon"
        case .textStats: return "Text Stats"
        case .miniBar:   return "Mini Bars"
        case .dot:       return "Dot"
        }
    }
}

// MARK: - Menu Bar Icon

struct MenuBarIconView: View {
    let state: MenuBarManager.SystemPressureLevel
    var cpuUsage: Double = 0
    var ramUsage: Double = 0

    @AppStorage("menuBarDisplayStyle") private var styleRaw = MenuBarDisplayStyle.icon.rawValue

    private var style: MenuBarDisplayStyle {
        MenuBarDisplayStyle(rawValue: styleRaw) ?? .icon
    }

    private var pressureColor: Color {
        switch state {
        case .normal:   return .haloGreen
        case .moderate: return .haloAmber
        case .critical: return .haloRed
        }
    }

    var body: some View {
        switch style {
        case .icon:      iconView
        case .textStats: textStatsView
        case .miniBar:   miniBarView
        case .dot:       dotView
        }
    }

    // Style: classic Halo icon with pressure shadow
    @ViewBuilder private var iconView: some View {
        let imageName = state == .normal ? "MenuBar_Standby" : "MenuBar_Processing"
        Image(imageName)
            .resizable()
            .interpolation(.high)
            .frame(width: 18, height: 18)
            .shadow(color: state == .normal ? .clear : pressureColor.opacity(0.8), radius: 3)
    }

    // Style: compact "47% · 68%" text
    @ViewBuilder private var textStatsView: some View {
        HStack(spacing: 4) {
            Text(String(format: "%.0f%%", cpuUsage * 100))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(cpuUsage > 0.85 ? .haloRed : cpuUsage > 0.60 ? .haloAmber : .primary)
            Text("·")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(String(format: "%.0f%%", ramUsage * 100))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(ramUsage > 0.90 ? .haloRed : ramUsage > 0.75 ? .haloAmber : .primary)
        }
        .frame(height: 18)
    }

    // Style: two thin horizontal bars
    @ViewBuilder private var miniBarView: some View {
        VStack(spacing: 2) {
            MiniProgressBar(value: cpuUsage,
                            color: cpuUsage > 0.85 ? .haloRed : cpuUsage > 0.60 ? .haloAmber : .haloAccent)
            MiniProgressBar(value: ramUsage,
                            color: ramUsage > 0.90 ? .haloRed : ramUsage > 0.75 ? .haloAmber : .haloCyan)
        }
        .frame(width: 28, height: 18)
    }

    // Style: single colored dot
    @ViewBuilder private var dotView: some View {
        Circle()
            .fill(pressureColor)
            .frame(width: 8, height: 8)
            .shadow(color: pressureColor.opacity(0.7), radius: 2)
            .frame(width: 18, height: 18)
    }
}

/// Thin progress bar used by the miniBar display style.
private struct MiniProgressBar: View {
    let value: Double   // 0.0–1.0
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(color)
                    .frame(width: max(2, geo.size.width * CGFloat(min(value, 1.0))))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Menu Bar Popover View

struct MenuBarPopoverView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var menuBarManager: MenuBarManager

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeader()
            Divider().background(Color.haloBorder)
            // Universal mic mute + camera status — always visible at the top
            MenuBarSystemControls()
            Divider().background(Color.haloBorder)
            MenuBarMetricsSection()
            Divider().background(Color.haloBorder)
            MenuBarStatsSection()
            Divider().background(Color.haloBorder)
            MenuBarQuickActions()
        }
        .frame(width: 300)
        .background(Color(hex: "#111827"))
        .cornerRadius(14)
        .onAppear {
            menuBarManager.update(from: appState)
            SystemControlsManager.shared.refreshAll()
        }
        .onChange(of: appState.cpuUsage) { _ in menuBarManager.update(from: appState) }
    }
}

// MARK: - System Controls section in menu bar popup

private struct MenuBarSystemControls: View {
    @ObservedObject private var ctrl = SystemControlsManager.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("PRIVACY & CONTROLS")
                    .font(HaloFont.body(9, weight: .semibold))
                    .foregroundColor(.haloText3)
                    .tracking(1.5)
                Spacer()
                MicCameraStatusBadges()
            }
            // Full three-pill compact row
            MicCameraControlsView(compact: true)
        }
        .padding(12)
    }
}

struct MenuBarHeader: View {
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.haloAccent, .haloAccent2],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                    .shadow(color: Color.haloAccent.opacity(0.5), radius: 4)
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            Text("Halo")
                .font(HaloFont.display(14, weight: .heavy))
                .foregroundColor(.haloText)

            // P3-05: VPN badge
            if appState.isVPNActive {
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.haloGreen)
                    Text("VPN")
                        .font(HaloFont.body(9, weight: .semibold))
                        .foregroundColor(.haloGreen)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.haloGreen.opacity(0.12))
                .cornerRadius(5)
            }

            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(menuBarManager.systemPressure.color)
                    .frame(width: 6, height: 6)
                    .shadow(color: menuBarManager.systemPressure.color.opacity(0.6), radius: 3)
                Text(menuBarManager.systemPressure == .normal ? "All Good"
                     : menuBarManager.systemPressure == .moderate ? "Moderate" : "Critical")
                    .font(HaloFont.body(11))
                    .foregroundColor(menuBarManager.systemPressure.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct MenuBarMetricsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            MenuBarRingCard(
                value: appState.cpuUsage,
                label: String(format: "%.0f%%", appState.cpuUsage * 100),
                subtitle: "CPU",
                color: .haloAccent
            )
            MenuBarRingCard(
                value: appState.ramUsage,
                label: String(format: "%.0f%%", appState.ramUsage * 100),
                subtitle: "RAM",
                color: appState.ramUsage > 0.8 ? .haloAmber : .haloPurple
            )
        }
        .padding(12)
    }
}

struct MenuBarRingCard: View {
    let value: Double
    let label: String
    let subtitle: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            HaloMiniRing(value: value, color: color, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(HaloFont.display(15, weight: .bold))
                    .foregroundColor(color)
                Text(subtitle)
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.haloSurface)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
    }
}

struct MenuBarStatsSection: View {
    @EnvironmentObject var appState: AppState
    // P3-09: respect module visibility settings
    @AppStorage("menuBarShowCPU")     private var showCPU     = true
    @AppStorage("menuBarShowRAM")     private var showRAM     = true
    @AppStorage("menuBarShowNet")     private var showNet     = true
    @AppStorage("menuBarShowBattery") private var showBattery = true
    @AppStorage("menuBarShowDisk")    private var showDisk    = false

    var body: some View {
        VStack(spacing: 8) {
            if showDisk {
                MenuBarStatRow(icon: "internaldrive", label: "Disk Free",
                               value: String(format: "%.0f GB", appState.diskFreeGB),
                               color: .haloGreen)
            }
            if showNet {
                MenuBarStatRow(icon: "arrow.up.circle", label: "Upload",
                               value: String(format: "%.1f MB/s", appState.networkUpMBps),
                               color: .haloCyan)
                MenuBarStatRow(icon: "arrow.down.circle", label: "Download",
                               value: String(format: "%.1f MB/s", appState.networkDownMBps),
                               color: .haloAccent)
            }
            if showBattery {
                MenuBarStatRow(
                    icon: appState.batteryIsCharging ? "bolt.fill" : "battery.75",
                    label: "Battery",
                    value: "\(appState.batteryPercent)%\(appState.batteryTimeRemaining.isEmpty ? "" : " · \(appState.batteryTimeRemaining)")",
                    color: appState.batteryPercent > 20 ? .haloGreen : .haloRed
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct MenuBarStatRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                    .frame(width: 16)
                Text(label)
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
            }
            Spacer()
            Text(value)
                .font(HaloFont.body(12, weight: .medium))
                .foregroundColor(.haloText)
        }
    }
}

struct MenuBarQuickActions: View {
    @EnvironmentObject var appState: AppState

    private let actions: [(icon: String, label: String, module: AppModule?)] = [
        ("sparkles", "Scan", .cleanup),
        ("bolt.fill", "Free RAM", nil),
        ("doc.on.clipboard.fill", "Clipboard", .clipboard),
        ("shield.fill", "Protect", .protection),
        ("folder.fill", "Lens", .files),
        ("gearshape.fill", "Settings", nil)
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("QUICK ACTIONS")
                    .font(HaloFont.body(9, weight: .semibold))
                    .foregroundColor(.haloText3)
                    .tracking(1.5)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(actions, id: \.label) { action in
                    MenuBarQuickActionButton(icon: action.icon, label: action.label) {
                        if let module = action.module {
                            appState.selectedModule = module
                        } else if action.label == "Free RAM" {
                            // Trigger RAM purge via XPC helper in production
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

struct MenuBarQuickActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(isHovered ? .haloAccent : .haloText2)
                Text(label)
                    .font(HaloFont.body(10))
                    .foregroundColor(isHovered ? .haloText : .haloText2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isHovered ? Color.haloAccent.opacity(0.08) : Color.haloSurface)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? Color.haloAccent.opacity(0.3) : Color.haloBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - In-app Menu Bar Preview

struct MenuBarPreviewView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var menuBarManager: MenuBarManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Menu Bar Agent")
                        .font(HaloFont.display(22, weight: .bold))
                        .foregroundColor(.haloText)
                    Text("Persistent ambient monitoring — one click from your Mac's vitals")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }

                HStack(alignment: .top, spacing: 24) {
                    // Live popover preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live Preview")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                        MenuBarPopoverView()
                            .cornerRadius(14)
                            .shadow(color: Color.black.opacity(0.4), radius: 24, y: 12)
                    }

                    // Feature cards
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Features")
                            .font(HaloFont.display(15, weight: .semibold))
                            .foregroundColor(.haloText)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            MenuBarFeatureCard(icon: "circle.grid.2x1.fill", title: "CPU + RAM Rings",
                                desc: "Dual animated rings refreshed every 2s. Color shifts with pressure level.")
                            MenuBarFeatureCard(icon: "network", title: "Network Speed",
                                desc: "Live upload & download bandwidth shown in the menu bar itself.")
                            MenuBarFeatureCard(icon: "bell.badge.fill", title: "Smart Alerts",
                                desc: "Disk < 5 GB, RAM critical, new background agent detected.")
                            MenuBarFeatureCard(icon: "doc.on.clipboard.fill", title: "Clipboard Quick Paste",
                                desc: "Last 5 items accessible without opening the full app.")
                            MenuBarFeatureCard(icon: "bolt.fill", title: "One-Click Free RAM",
                                desc: "Purge inactive memory from the popover instantly.")
                            MenuBarFeatureCard(icon: "paintbrush.fill", title: "Dynamic Icon",
                                desc: "Icon glow reflects system health — green, amber, or red.")
                        }
                    }
                }
            }
            .padding(28)
        }
        .background(Color.haloSurface)
    }
}

struct MenuBarFeatureCard: View {
    let icon: String
    let title: String
    let desc: String

    var body: some View {
        HaloCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.haloAccent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.haloText)
                    Text(desc)
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }
}
