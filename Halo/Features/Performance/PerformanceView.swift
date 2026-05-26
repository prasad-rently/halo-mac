import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = PerformanceViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                PerformanceHeader()
                LiveMetricsRow()
                RAMOptimizerCard(viewModel: viewModel)
                // P3-01: Per-core CPU breakdown
                CPUCoresSection()
                // P3-11: Top processes
                TopProcessesSection()
                // P3-04: Battery deep intel
                BatteryDetailSection()
                // P3-02: Thermal sensors & fans
                SensorsSection()
                // P3-05/06: Network + Speed Test
                NetworkDetailSection()
                LoginItemsSection(viewModel: viewModel)
                MaintenanceSection(viewModel: viewModel)
            }
            .padding(28)
        }
        .background(Color.haloSurface)
        .task { await viewModel.loadLoginItems() }
    }
}

// MARK: - ViewModel

@MainActor
final class PerformanceViewModel: ObservableObject {
    @Published var loginItems: [LoginItem] = []
    @Published var isLoadingLoginItems = false
    @Published var ramFreedMB: Double? = nil
    @Published var isFreingRAM = false
    @Published var maintenanceTasks: [SystemMaintenanceTask] = SystemMaintenanceTask.defaults

    func loadLoginItems() async {
        isLoadingLoginItems = true
        // In production: use SMAppService + LaunchAgent plist enumeration
        loginItems = LoginItem.samples
        isLoadingLoginItems = false
    }

    func toggleLoginItem(_ item: LoginItem) {
        if let idx = loginItems.firstIndex(where: { $0.id == item.id }) {
            loginItems[idx].isEnabled.toggle()
            // In production: SMAppService.mainApp.register() / unregister()
        }
    }

    func freeRAM() async {
        isFreingRAM = true
        let before = ramUsedGB()
        // In production: call XPC helper which runs malloc_zone_pressure_relief + purge
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let after = before * 0.88 // simulate ~12% freed
        ramFreedMB = (before - after) * 1024
        isFreingRAM = false
    }

    func runMaintenance(_ task: SystemMaintenanceTask) async {
        guard let idx = maintenanceTasks.firstIndex(where: { $0.id == task.id }) else { return }
        maintenanceTasks[idx].isRunning = true
        // In production: call XPC helper with appropriate shell command
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        maintenanceTasks[idx].lastRunDate = Date()
        maintenanceTasks[idx].isRunning = false
    }

    private func ramUsedGB() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024) * 0.7
    }
}

extension LoginItem {
    static let samples: [LoginItem] = [
        .init(name: "Spotify Helper", bundleIdentifier: "com.spotify.helper",
              path: "~/Library/LaunchAgents/com.spotify.helper.plist",
              isEnabled: true, ramUsageMB: 18, lastLaunchedDate: Date(), kind: .loginItem),
        .init(name: "OneDrive", bundleIdentifier: "com.microsoft.OneDrive",
              path: "~/Library/LaunchAgents/com.microsoft.OneDrive.plist",
              isEnabled: true, ramUsageMB: 94, lastLaunchedDate: Date(), kind: .loginItem, isSuspicious: false),
        .init(name: "com.adobe.agsService", bundleIdentifier: "com.adobe.agsService",
              path: "~/Library/LaunchAgents/com.adobe.agsService.plist",
              isEnabled: false, ramUsageMB: 0, lastLaunchedDate: nil, kind: .launchAgent, isSuspicious: true),
        .init(name: "Mimestream", bundleIdentifier: "com.mimestream.Mimestream",
              path: "~/Library/LaunchAgents/com.mimestream.plist",
              isEnabled: true, ramUsageMB: 42, lastLaunchedDate: Date(), kind: .loginItem),
        .init(name: "Raycast", bundleIdentifier: "com.raycast.macos",
              path: "~/Library/LaunchAgents/com.raycast.plist",
              isEnabled: true, ramUsageMB: 55, lastLaunchedDate: Date(), kind: .loginItem),
    ]
}

extension SystemMaintenanceTask {
    static let defaults: [SystemMaintenanceTask] = [
        .init(title: "Flush DNS Cache", description: "Clears DNS resolver cache, fixing connectivity issues",
              icon: "wifi", lastRunDate: nil),
        .init(title: "Rebuild Spotlight Index", description: "Re-indexes system for faster Spotlight searches",
              icon: "magnifyingglass.circle.fill", lastRunDate: Date().addingTimeInterval(-604800)),
        .init(title: "Repair Disk Permissions", description: "Fixes incorrect file permission settings",
              icon: "lock.rotation", lastRunDate: Date().addingTimeInterval(-1209600)),
        .init(title: "Clear Font Cache", description: "Resolves font rendering artifacts and duplicates",
              icon: "textformat", lastRunDate: nil),
    ]
}

// MARK: - Header

struct PerformanceHeader: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Performance")
                    .font(HaloFont.display(22, weight: .bold))
                    .foregroundColor(.haloText)
                Text("CPU · RAM · Battery · Sensors · Network · Processes")
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText2)
            }
            Spacer()
        }
    }
}

// MARK: - Live Metrics Row

struct LiveMetricsRow: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            LiveMetricCard(
                label: "CPU Usage",
                value: String(format: "%.0f%%", appState.cpuUsage * 100),
                color: .haloAccent,
                sparkValues: [0.3, 0.45, 0.6, 0.35, 0.55, appState.cpuUsage]
            )
            LiveMetricCard(
                label: "RAM Pressure",
                value: String(format: "%.0f%%", appState.ramUsage * 100),
                color: appState.ramUsage > 0.8 ? .haloAmber : .haloPurple,
                sparkValues: [0.5, 0.65, 0.72, 0.68, 0.75, appState.ramUsage]
            )
            LiveMetricCard(
                label: "Battery Health",
                value: String(format: "%.0f%%", appState.batteryHealth * 100),
                color: .haloGreen,
                sparkValues: nil,
                subtitle: "Cycle count: \(appState.batteryCycles)"
            )
        }
    }
}

struct LiveMetricCard: View {
    let label: String
    let value: String
    let color: Color
    let sparkValues: [Double]?
    var subtitle: String? = nil

    var body: some View {
        HaloCard(accentTop: color) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
                Text(value)
                    .font(HaloFont.display(28, weight: .bold))
                    .foregroundColor(color)
                if let sub = subtitle {
                    Text(sub)
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
                if let values = sparkValues {
                    HaloSparkline(values: values, color: color, height: 36)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - RAM Optimizer

struct RAMOptimizerCard: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var viewModel: PerformanceViewModel

    var body: some View {
        HaloCard {
            HStack(spacing: 20) {
                // RAM breakdown
                VStack(alignment: .leading, spacing: 10) {
                    Text("RAM Breakdown")
                        .font(HaloFont.display(14, weight: .semibold))
                        .foregroundColor(.haloText)

                    RAMSegmentRow(label: "Wired", value: appState.ramUsedGB * 0.2, total: appState.ramTotalGB, color: .haloRed)
                    RAMSegmentRow(label: "Active", value: appState.ramUsedGB * 0.45, total: appState.ramTotalGB, color: .haloAccent)
                    RAMSegmentRow(label: "Compressed", value: appState.ramUsedGB * 0.1, total: appState.ramTotalGB, color: .haloAmber)
                    RAMSegmentRow(label: "Inactive", value: appState.ramTotalGB * 0.15, total: appState.ramTotalGB, color: .haloText3)
                }
                .frame(maxWidth: .infinity)

                Divider().background(Color.haloBorder)

                // Free RAM action
                VStack(spacing: 12) {
                    Text("Optimize Memory")
                        .font(HaloFont.display(14, weight: .semibold))
                        .foregroundColor(.haloText)

                    ZStack {
                        Circle()
                            .stroke(Color.haloBorder, lineWidth: 6)
                            .frame(width: 80, height: 80)
                        Circle()
                            .trim(from: 0, to: appState.ramUsage)
                            .stroke(appState.ramUsage > 0.8 ? Color.haloAmber : Color.haloAccent,
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 1) {
                            Text(String(format: "%.0f%%", appState.ramUsage * 100))
                                .font(HaloFont.display(16, weight: .bold))
                                .foregroundColor(.haloText)
                            Text("used")
                                .font(HaloFont.body(10))
                                .foregroundColor(.haloText2)
                        }
                    }

                    if let freed = viewModel.ramFreedMB {
                        Text(String(format: "+%.0f MB freed", freed))
                            .font(HaloFont.body(12, weight: .semibold))
                            .foregroundColor(.haloGreen)
                    }

                    HaloPrimaryButton("Free RAM", icon: "bolt.fill", isLoading: viewModel.isFreingRAM) {
                        Task { await viewModel.freeRAM() }
                    }
                }
                .frame(width: 160)
            }
            .padding(20)
        }
    }
}

struct RAMSegmentRow: View {
    let label: String
    let value: Double
    let total: Double
    let color: Color

    var ratio: Double { total > 0 ? value / total : 0 }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(HaloFont.body(12))
                .foregroundColor(.haloText2)
                .frame(width: 80, alignment: .leading)
            HaloMiniBar(value: ratio, color: color)
            Text(String(format: "%.1f GB", value))
                .font(HaloFont.body(11, weight: .medium))
                .foregroundColor(.haloText)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

// MARK: - Login Items

struct LoginItemsSection: View {
    @ObservedObject var viewModel: PerformanceViewModel

    var flaggedCount: Int { viewModel.loginItems.filter { $0.isSuspicious || $0.isUnused }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(
                title: "Login Items",
                subtitle: flaggedCount > 0 ? "\(flaggedCount) flagged" : "All clean",
                action: {},
                actionLabel: "Manage All"
            )
            if viewModel.isLoadingLoginItems {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 6) {
                    ForEach(viewModel.loginItems) { item in
                        LoginItemRow(item: item) {
                            viewModel.toggleLoginItem(item)
                        }
                    }
                }
            }
        }
    }
}

struct LoginItemRow: View {
    let item: LoginItem
    let onToggle: () -> Void

    @State private var isEnabled: Bool

    init(item: LoginItem, onToggle: @escaping () -> Void) {
        self.item = item
        self.onToggle = onToggle
        _isEnabled = State(initialValue: item.isEnabled)
    }

    private var flagColor: Color? {
        if item.isSuspicious { return .haloRed }
        if item.isUnused { return .haloAmber }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill((flagColor ?? .haloAccent).opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "app.badge")
                    .font(.system(size: 14))
                    .foregroundColor(flagColor ?? .haloAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(HaloFont.body(13, weight: .medium))
                    .foregroundColor(.haloText)
                HStack(spacing: 6) {
                    if item.ramUsageMB > 0 {
                        Text(String(format: "%.0f MB RAM", item.ramUsageMB))
                            .font(HaloFont.body(11))
                            .foregroundColor(item.ramUsageMB > 80 ? .haloAmber : .haloText2)
                    }
                    if item.isSuspicious {
                        Text("⚠ Unknown origin")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloRed)
                    } else if item.isUnused {
                        Text("Not used in 90+ days")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloAmber)
                    }
                }
            }

            Spacer()

            HaloToggle(isOn: $isEnabled)
                .onChange(of: isEnabled) { _ in onToggle() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(flagColor.map { $0.opacity(0.2) } ?? Color.haloBorder, lineWidth: 1)
        )
    }
}

// MARK: - Maintenance

struct MaintenanceSection: View {
    @ObservedObject var viewModel: PerformanceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaloSectionHeader(title: "Maintenance Scripts",
                              subtitle: "Run low-level system repair tasks")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(viewModel.maintenanceTasks) { task in
                    MaintenanceTaskCard(task: task) {
                        Task { await viewModel.runMaintenance(task) }
                    }
                }
            }
        }
    }
}

struct MaintenanceTaskCard: View {
    let task: SystemMaintenanceTask
    let onRun: () -> Void

    var body: some View {
        HaloCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.haloAccent.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: task.icon)
                        .font(.system(size: 15))
                        .foregroundColor(.haloAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.haloText)
                    Text(task.description)
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                        .lineLimit(2)
                    Text("Last run: \(task.lastRunFormatted)")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }

                Spacer()

                Button(action: onRun) {
                    if task.isRunning {
                        ProgressView().scaleEffect(0.7).tint(.haloAccent)
                    } else {
                        Text("Run")
                            .font(HaloFont.body(11, weight: .semibold))
                            .foregroundColor(.haloAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.haloAccent.opacity(0.1))
                            .cornerRadius(7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.haloAccent.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(task.isRunning)
            }
            .padding(14)
        }
    }
}
