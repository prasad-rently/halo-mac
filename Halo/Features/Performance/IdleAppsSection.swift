import SwiftUI

// MARK: - IdleAppsViewModel

@MainActor
final class IdleAppsViewModel: ObservableObject {

    @Published var idleApps: [IdleApp] = []
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "idleAppMonitorEnabled")
    @Published var timeoutMinutes: Int = UserDefaults.standard.object(forKey: "idleAppTimeout") as? Int ?? 60
    @Published var mode: IdleAppMode = {
        let raw = UserDefaults.standard.string(forKey: "idleAppMode") ?? "suggest"
        return IdleAppMode(rawValue: raw) ?? .suggest
    }()
    @Published var excludeList: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "idleAppExcludeList") ?? []
        return Set(saved)
    }()
    @Published var statusMessage: String?

    // Daily stats
    @Published var appsQuitToday: Int = UserDefaults.standard.integer(forKey: "idleAppsQuitToday")
    @Published var ramRecoveredTodayMB: Double = UserDefaults.standard.double(forKey: "idleRamRecoveredToday")

    // Confirmation
    @Published var showQuitConfirm = false
    @Published var pendingQuitApp: IdleApp?

    private let monitor = IdleAppMonitor()
    private var refreshTimer: Timer?

    enum IdleAppMode: String, CaseIterable, Identifiable {
        case suggest  = "Suggest"
        case autoQuit = "Auto-Quit"
        var id: String { rawValue }
    }

    // MARK: - Lifecycle

    func start() {
        guard isEnabled else { return }
        Task { await monitor.startMonitoring() }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        Task { await monitor.stopMonitoring() }
    }

    func refresh() async {
        guard isEnabled else { idleApps = []; return }
        let timeout = TimeInterval(timeoutMinutes * 60)
        idleApps = await monitor.idleApps(timeout: timeout, excludeList: excludeList)

        // Reset daily stats if day changed
        let todayKey = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let savedDay = UserDefaults.standard.double(forKey: "idleStatsDay")
        if todayKey != savedDay {
            appsQuitToday = 0
            ramRecoveredTodayMB = 0
            UserDefaults.standard.set(todayKey, forKey: "idleStatsDay")
            UserDefaults.standard.set(0, forKey: "idleAppsQuitToday")
            UserDefaults.standard.set(0.0, forKey: "idleRamRecoveredToday")
        }
    }

    // MARK: - Actions

    func requestQuit(_ app: IdleApp) {
        pendingQuitApp = app
        showQuitConfirm = true
    }

    func confirmQuit() {
        guard let app = pendingQuitApp else { return }
        showQuitConfirm = false
        Task { await performQuit(app) }
    }

    func quitAllIdle() async {
        let targets = idleApps
        for app in targets {
            await performQuit(app)
        }
    }

    private func performQuit(_ app: IdleApp) async {
        let (success, ramFreed) = await monitor.quitApp(bundleID: app.id)
        if success {
            idleApps.removeAll { $0.id == app.id }
            appsQuitToday += 1
            ramRecoveredTodayMB += ramFreed
            UserDefaults.standard.set(appsQuitToday, forKey: "idleAppsQuitToday")
            UserDefaults.standard.set(ramRecoveredTodayMB, forKey: "idleRamRecoveredToday")
            statusMessage = "Quit \(app.name) — freed \(app.ramFormatted)"
        } else {
            statusMessage = "Failed to quit \(app.name)"
        }
        clearStatusAfterDelay()
    }

    func addToExcludeList(_ bundleID: String) {
        excludeList.insert(bundleID)
        persistExcludeList()
        idleApps.removeAll { $0.id == bundleID }
    }

    func removeFromExcludeList(_ bundleID: String) {
        excludeList.remove(bundleID)
        persistExcludeList()
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "idleAppMonitorEnabled")
        if enabled { start() } else { stop(); idleApps = [] }
    }

    func setTimeout(_ minutes: Int) {
        timeoutMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "idleAppTimeout")
    }

    func setMode(_ mode: IdleAppMode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "idleAppMode")
    }

    // MARK: - Private

    private func persistExcludeList() {
        UserDefaults.standard.set(Array(excludeList), forKey: "idleAppExcludeList")
    }

    private func clearStatusAfterDelay() {
        let msg = statusMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.statusMessage == msg { self?.statusMessage = nil }
        }
    }
}

// MARK: - IdleAppsSection

struct IdleAppsSection: View {
    @StateObject private var viewModel = IdleAppsViewModel()
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(
                title: "Idle Apps",
                subtitle: viewModel.isEnabled
                    ? "\(viewModel.idleApps.count) idle · \(viewModel.timeoutMinutes)m timeout"
                    : "Disabled",
                action: { withAnimation { isExpanded.toggle() } },
                actionLabel: isExpanded ? "Hide" : "Show"
            )

            if isExpanded {
                // Enable toggle + settings row
                IdleAppsSettingsRow(viewModel: viewModel)

                // Daily stats
                if viewModel.isEnabled && viewModel.appsQuitToday > 0 {
                    IdleAppsDailyStats(viewModel: viewModel)
                }

                // Status message
                if let msg = viewModel.statusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.haloGreen)
                            .font(.system(size: 11))
                        Text(msg)
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.haloGreen.opacity(0.08))
                    .cornerRadius(8)
                    .transition(.opacity)
                }

                if viewModel.isEnabled {
                    if viewModel.idleApps.isEmpty {
                        HaloCard {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                    .foregroundColor(.haloGreen)
                                Text("No idle apps detected")
                                    .font(HaloFont.body(12))
                                    .foregroundColor(.haloText2)
                                Spacer()
                            }
                            .padding(14)
                        }
                    } else {
                        // Idle app list
                        VStack(spacing: 2) {
                            ForEach(viewModel.idleApps) { app in
                                IdleAppRow(app: app, viewModel: viewModel)
                            }
                        }
                        .background(Color.haloSurface2)
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloBorder, lineWidth: 1))

                        // Quit all button
                        if viewModel.idleApps.count > 1 {
                            Button {
                                Task { await viewModel.quitAllIdle() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark.app")
                                    let totalRAM = viewModel.idleApps.reduce(0.0) { $0 + $1.ramMB }
                                    Text("Quit All (\(viewModel.idleApps.count) apps, ~\(String(format: "%.0f", totalRAM)) MB)")
                                }
                                .font(HaloFont.body(12, weight: .medium))
                                .foregroundColor(.haloRed)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.haloRed.opacity(0.1))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloRed.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .alert("Quit App", isPresented: $viewModel.showQuitConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Quit", role: .destructive) { viewModel.confirmQuit() }
        } message: {
            if let app = viewModel.pendingQuitApp {
                Text("Quit \(app.name)? It has been idle for \(app.idleDurationFormatted) and is using \(app.ramFormatted) of RAM.")
            }
        }
    }
}

// MARK: - Settings Row

private struct IdleAppsSettingsRow: View {
    @ObservedObject var viewModel: IdleAppsViewModel

    private let timeoutOptions = [15, 30, 60, 120]

    var body: some View {
        HaloCard {
            VStack(spacing: 12) {
                HStack {
                    Text("Monitor idle apps")
                        .font(HaloFont.body(12, weight: .medium))
                        .foregroundColor(.haloText)
                    Spacer()
                    // Shared HaloToggle (matches the Login Items switch style).
                    HaloToggle(isOn: Binding(
                        get: { viewModel.isEnabled },
                        set: { viewModel.setEnabled($0) }
                    ))
                }

                if viewModel.isEnabled {
                    HStack(spacing: 16) {
                        // Timeout picker
                        HStack(spacing: 6) {
                            Text("Timeout:")
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText3)
                            Picker("", selection: Binding(
                                get: { viewModel.timeoutMinutes },
                                set: { viewModel.setTimeout($0) }
                            )) {
                                ForEach(timeoutOptions, id: \.self) { min in
                                    Text(min < 60 ? "\(min)m" : "\(min/60)h").tag(min)
                                }
                            }
                            .frame(width: 70)
                        }

                        // Mode picker
                        HStack(spacing: 6) {
                            Text("Mode:")
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText3)
                            Picker("", selection: Binding(
                                get: { viewModel.mode },
                                set: { viewModel.setMode($0) }
                            )) {
                                ForEach(IdleAppsViewModel.IdleAppMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                        }

                        Spacer()
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Daily Stats

private struct IdleAppsDailyStats: View {
    @ObservedObject var viewModel: IdleAppsViewModel

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.app.fill")
                    .foregroundColor(.haloAccent)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Apps quit today")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                    Text("\(viewModel.appsQuitToday)")
                        .font(HaloFont.display(16, weight: .bold))
                        .foregroundColor(.haloText)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "memorychip.fill")
                    .foregroundColor(.haloGreen)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text("RAM recovered")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                    let ramText = viewModel.ramRecoveredTodayMB >= 1024
                        ? String(format: "%.1f GB", viewModel.ramRecoveredTodayMB / 1024)
                        : String(format: "%.0f MB", viewModel.ramRecoveredTodayMB)
                    Text(ramText)
                        .font(HaloFont.display(16, weight: .bold))
                        .foregroundColor(.haloGreen)
                }
            }

            Spacer()
        }
        .padding(14)
        .background(Color.haloSurface2)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - Idle App Row

private struct IdleAppRow: View {
    let app: IdleApp
    @ObservedObject var viewModel: IdleAppsViewModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // App icon
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.haloSurface2)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "app.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.haloText3)
                    )
            }

            // Name + idle duration
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                Text(app.idleDurationFormatted)
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloAmber)
            }

            Spacer()

            // RAM usage
            Text(app.ramFormatted)
                .font(HaloFont.mono(11))
                .foregroundColor(.haloText2)

            // Actions
            HStack(spacing: 6) {
                Button {
                    viewModel.requestQuit(app)
                } label: {
                    Text("Quit")
                        .font(HaloFont.body(10, weight: .semibold))
                        .foregroundColor(.haloRed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.haloRed.opacity(0.1))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("performance.idleApp.quit.button")

                Menu {
                    Button("Quit \(app.name)") { viewModel.requestQuit(app) }
                    Divider()
                    Button("Exclude \"\(app.name)\"") {
                        viewModel.addToExcludeList(app.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.haloText3)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovered ? Color.haloAccent.opacity(0.04) : Color.clear)
        .onHover { isHovered = $0 }
    }
}
