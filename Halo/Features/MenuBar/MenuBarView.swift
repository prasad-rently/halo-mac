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

// MARK: - Menu Bar Icon

struct MenuBarIconView: View {
    let state: MenuBarManager.SystemPressureLevel

    private var imageName: String {
        state == .normal ? "MenuBar_Standby" : "MenuBar_Processing"
    }

    var body: some View {
        Image(imageName)
            .resizable()
            .interpolation(.high)
            .frame(width: 18, height: 18)
            // Tint: amber/red glow under load, no tint at normal state
            .shadow(color: state == .normal ? .clear
                    : state == .moderate ? Color.haloAmber.opacity(0.8)
                    : Color.haloRed.opacity(0.8), radius: 3)
    }
}

// MARK: - Menu Bar Popover View

struct MenuBarPopoverView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var menuBarManager: MenuBarManager
    @StateObject private var displaysVM = DisplaysViewModel()

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeader()
            Divider().background(Color.haloBorder)
            MenuBarMetricsSection()
            Divider().background(Color.haloBorder)
            MenuBarStatsSection()
            Divider().background(Color.haloBorder)
            MenuBarBrightnessSection(viewModel: displaysVM)
            Divider().background(Color.haloBorder)
            MenuBarQuickActions()
        }
        .frame(width: 300)
        .background(Color(hex: "#111827"))
        .cornerRadius(14)
        .task { await displaysVM.load() }
        .onAppear { menuBarManager.update(from: appState) }
        .onChange(of: appState.cpuUsage) { _ in menuBarManager.update(from: appState) }
    }
}

struct MenuBarHeader: View {
    @EnvironmentObject var menuBarManager: MenuBarManager

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

    var body: some View {
        VStack(spacing: 8) {
            MenuBarStatRow(icon: "internaldrive", label: "Disk Free",
                           value: String(format: "%.0f GB", appState.diskFreeGB),
                           color: .haloGreen)
            MenuBarStatRow(icon: "arrow.up.circle", label: "Upload",
                           value: String(format: "%.1f MB/s", appState.networkUpMBps),
                           color: .haloCyan)
            MenuBarStatRow(icon: "arrow.down.circle", label: "Download",
                           value: String(format: "%.1f MB/s", appState.networkDownMBps),
                           color: .haloAccent)
            MenuBarStatRow(icon: "battery.75", label: "Battery",
                           value: "\(appState.batteryPercent)%\(appState.batteryTimeRemaining.isEmpty ? "" : " · \(appState.batteryTimeRemaining)")",
                           color: appState.batteryPercent > 20 ? .haloGreen : .haloRed)
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

// MARK: - Menu Bar Brightness Section

struct MenuBarBrightnessSection: View {
    @ObservedObject var viewModel: DisplaysViewModel

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.haloAccent)
                Text("BRIGHTNESS")
                    .font(HaloFont.body(9, weight: .semibold))
                    .foregroundColor(.haloText3)
                    .tracking(1.5)
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }
            }

            if viewModel.displays.isEmpty && !viewModel.isLoading {
                Text("No controllable displays")
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach($viewModel.displays) { $display in
                    MenuBarBrightnessRow(
                        display: $display,
                        onBrightnessChange: { newValue in
                            viewModel.setBrightnessImmediate(newValue, for: display.id)
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct MenuBarBrightnessRow: View {
    @Binding var display: ConnectedDisplay
    let onBrightnessChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: display.typeIcon)
                    .font(.system(size: 10))
                    .foregroundColor(display.isBuiltIn ? .haloAccent : .haloAccent2)
                    .frame(width: 14)

                Text(display.name)
                    .font(HaloFont.body(11, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("\(Int(display.brightness * 100))%")
                    .font(HaloFont.mono(11))
                    .foregroundColor(display.isBuiltIn ? .haloAccent : .haloAccent2)
                    .frame(width: 32, alignment: .trailing)
            }

            if display.isDDCCapable || display.isBuiltIn {
                Slider(value: Binding(
                    get: { display.brightness },
                    set: { onBrightnessChange($0) }
                ), in: 0.02...1.0)
                .tint(display.isBuiltIn ? .haloAccent : .haloAccent2)
            } else {
                Text("DDC not supported")
                    .font(HaloFont.body(9))
                    .foregroundColor(.haloAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Quick Actions

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
