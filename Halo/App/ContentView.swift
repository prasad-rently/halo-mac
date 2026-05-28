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
    @State private var isEditing = false

    var body: some View {
        VStack(spacing: 0) {

            // ── Logo header ──────────────────────────────────────────────
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

                // Customise / Done button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
                } label: {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "slider.horizontal.3")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isEditing ? .haloGreen : .haloText3)
                }
                .buttonStyle(.plain)
                .help(isEditing ? "Done customising" : "Customise module order")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            Divider().background(Color.haloBorder)

            // ── Module list ──────────────────────────────────────────────
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {

                    // "Overview" section — Dashboard is always pinned here
                    if !isEditing {
                        SidebarSection(label: "Overview") {
                            SidebarItem(module: .dashboard)
                        }
                    }

                    // "Modules" section — user-reorderable
                    SidebarSection(label: isEditing ? "Drag to reorder" : "Modules") {
                        // We use a fixed-height List so SwiftUI's .onMove drag
                        // handles work while the outer ScrollView handles overflow.
                        List {
                            ForEach(appState.moduleOrder, id: \.self) { module in
                                let info = badgeInfo(for: module)
                                SidebarItem(
                                    module:      module,
                                    badge:       info.text,
                                    badgeColor:  info.color,
                                    isEditing:   isEditing
                                )
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                            }
                            .onMove { appState.moveModules(from: $0, to: $1) }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        // Height = number of modules × row height (44 pt each)
                        .frame(height: CGFloat(appState.moduleOrder.count) * 44)
                        // Note: on macOS, List + .onMove is always drag-active.
                        // EditMode is an iOS-only concept and is not used here.
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

    // ── Badge data per module ────────────────────────────────────────────
    // Centralised so the dynamic ForEach can call it rather than having
    // badge values hardcoded next to each SidebarItem call.

    private func badgeInfo(for module: AppModule) -> (text: String?, color: Color) {
        switch module {
        case .cleanup:
            let bytes = appState.totalCleanableBytes
            return (bytes > 0
                ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                : nil,
                    .haloAccent)
        case .protection:
            return ("Safe", .haloGreen)
        case .performance:
            return ("3", .haloAmber)
        case .clipboard:
            return (appState.clipboardItems.isEmpty
                ? nil
                : "\(appState.clipboardItems.count)",
                    .haloAmber)
        default:
            return (nil, .haloAccent)
        }
    }
}

// MARK: - Sidebar Section

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

// MARK: - Sidebar Item

struct SidebarItem: View {
    @EnvironmentObject var appState: AppState
    let module: AppModule
    var badge: String? = nil
    var badgeColor: Color = .haloAccent
    var isEditing: Bool = false

    private var isActive: Bool { appState.selectedModule == module }

    var body: some View {
        Button {
            // Suppress navigation while the user is in edit/reorder mode
            guard !isEditing else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                appState.selectedModule = module
            }
        } label: {
            HStack(spacing: 10) {
                // Module icon
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(
                            colors: isActive && !isEditing
                                ? module.gradientColors
                                : [Color.white.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: module.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isActive && !isEditing ? .white : .haloText2)
                }

                Text(module.title)
                    .font(HaloFont.body(13, weight: .medium))
                    .foregroundColor(isActive && !isEditing ? .haloText : .haloText2)

                Spacer()

                if isEditing {
                    // Drag handle hint — SwiftUI List renders the system handle
                    // beside this; we echo it with our own icon so it's visible
                    // before the user touches the row.
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundColor(.haloText3)
                } else if let badge = badge {
                    HaloBadge(text: badge, color: badgeColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive && !isEditing
                          ? LinearGradient(
                              colors: [Color.haloAccent.opacity(0.12), Color.haloAccent2.opacity(0.08)],
                              startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [.clear],
                                           startPoint: .leading, endPoint: .trailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActive && !isEditing
                            ? Color.haloAccent.opacity(0.2)
                            : .clear,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .opacity(isEditing ? 0.80 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isEditing)
    }
}

// MARK: - Storage Indicator

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
