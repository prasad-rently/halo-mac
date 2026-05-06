import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.isOnboardingComplete {
                OnboardingView()
            } else {
                MainLayout()
            }
        }
        .background(Color.haloBackground)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Main Layout

struct MainLayout: View {
    @EnvironmentObject var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
        } detail: {
            DetailView()
        }
        .background(Color.haloBackground)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Logo
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [.haloAccent, .haloAccent2],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                .shadow(color: Color.haloAccent.opacity(0.5), radius: 6)
                Text("Halo")
                    .font(HaloFont.display(18, weight: .heavy))
                    .foregroundColor(.haloText)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            Divider()
                .background(Color.haloBorder)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    SidebarSection(label: "Overview") {
                        SidebarItem(module: .dashboard)
                    }

                    SidebarSection(label: "Modules") {
                        SidebarItem(module: .cleanup,
                                    badge: appState.totalCleanableBytes > 0
                                        ? ByteCountFormatter.string(fromByteCount: appState.totalCleanableBytes, countStyle: .file)
                                        : nil)
                        SidebarItem(module: .protection, badge: "Safe", badgeColor: .haloGreen)
                        SidebarItem(module: .performance, badge: "3", badgeColor: .haloAmber)
                        SidebarItem(module: .applications)
                        SidebarItem(module: .files)
                        SidebarItem(module: .clipboard,
                                    badge: appState.clipboardItems.isEmpty ? nil : "\(appState.clipboardItems.count)",
                                    badgeColor: .haloAmber)
                    }
                }
                .padding(.vertical, 8)
            }

            Spacer()
            StorageIndicator()
                .padding(12)
        }
        .background(Color.haloBackground.opacity(0.8))
        .listStyle(.sidebar)
    }
}

struct SidebarSection<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(HaloFont.body(10, weight: .semibold))
                .foregroundColor(.haloText3)
                .tracking(1.5)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            content
        }
    }
}

struct SidebarItem: View {
    @EnvironmentObject var appState: AppState
    let module: AppModule
    var badge: String? = nil
    var badgeColor: Color = .haloAccent

    private var isActive: Bool { appState.selectedModule == module }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                appState.selectedModule = module
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(
                            colors: isActive ? module.gradientColors : [Color.white.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: module.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isActive ? .white : .haloText2)
                }

                Text(module.title)
                    .font(HaloFont.body(13, weight: .medium))
                    .foregroundColor(isActive ? .haloText : .haloText2)

                Spacer()

                if let badge = badge {
                    HaloBadge(text: badge, color: badgeColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive
                          ? LinearGradient(colors: [Color.haloAccent.opacity(0.12), Color.haloAccent2.opacity(0.08)],
                                           startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActive ? Color.haloAccent.opacity(0.2) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

struct StorageIndicator: View {
    @EnvironmentObject var appState: AppState

    private var usageRatio: Double {
        guard appState.diskTotalGB > 0 else { return 0 }
        return (appState.diskTotalGB - appState.diskFreeGB) / appState.diskTotalGB
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Macintosh HD")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
                Spacer()
                Text("\(Int(usageRatio * 100))%")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText3)
            }
            HaloMiniBar(value: usageRatio, color: .haloAccent)
            HStack {
                Text(String(format: "%.0f GB used", appState.diskTotalGB - appState.diskFreeGB))
                    .font(HaloFont.body(11, weight: .semibold))
                    .foregroundColor(.haloText)
                Spacer()
                Text(String(format: "%.0f GB", appState.diskTotalGB))
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
            }
        }
        .padding(14)
        .background(Color.haloSurface2)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - Detail Router

struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.haloSurface.ignoresSafeArea()
            switch appState.selectedModule {
            case .dashboard:    DashboardView()
            case .cleanup:      CleanupView()
            case .protection:   ProtectionView()
            case .performance:  PerformanceView()
            case .applications: ApplicationsView()
            case .files:        FilesView()
            case .clipboard:    ClipboardView()
            case .menuBarPreview: MenuBarPreviewView()
            }
        }
        .background(Color.haloSurface)
    }
}
