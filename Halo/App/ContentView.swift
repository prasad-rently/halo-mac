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
    @StateObject private var celebrationManager = CelebrationManager.shared
    @ObservedObject private var actionRunner = ActionRunner.shared
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
            } detail: {
                DetailView()
            }

            // F-037: Celebration overlay — sits above all content, non-interactive
            CelebrationOverlay(manager: celebrationManager)
        }
        .background(Color.haloBackground)
        // F-038: Code Beautifier sheet — triggered from Actions module
        .sheet(isPresented: $actionRunner.showCodeBeautifier) {
            CodeBeautifierView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false

    var body: some View {
        // The module list is the ONLY scrollable region. Header and storage
        // indicator are attached as safeAreaInsets rather than VStack siblings
        // around a Spacer — with the old VStack+Spacer+ScrollView layout, some
        // selections (rows near the bottom of the list) intermittently left the
        // header and storage indicator unrendered, as if the ScrollView had
        // stolen their space or the whole column had scrolled past them. Insets
        // are guaranteed by SwiftUI to stay pinned outside the scrollable content
        // no matter what happens inside the ScrollView, which removes that whole
        // failure mode rather than chasing its trigger.
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
                    if isEditing {
                        // List is only mounted while actively dragging to reorder —
                        // its AppKit-backed NSTableView is needed for .onMove, but
                        // keeping it mounted during normal navigation caused taps on
                        // rows near the bottom (e.g. AI Assistant) to trigger AppKit's
                        // "scroll to reveal first responder" behavior on the table,
                        // snapping the whole sidebar's scroll position to a wrong spot.
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
                        // 46 pt per row — macOS List rows render slightly taller than 44 pt
                        // due to internal padding; this ensures all modules always stay visible.
                        .frame(height: CGFloat(appState.moduleOrder.count) * 46)
                        // Note: on macOS, List + .onMove is always drag-active.
                        // EditMode is an iOS-only concept and is not used here.
                    } else {
                        // Plain SwiftUI stack for normal navigation — no NSTableView,
                        // so tapping a row can't trigger the scroll-to-focus glitch above.
                        VStack(spacing: 2) {
                            ForEach(appState.moduleOrder, id: \.self) { module in
                                let info = badgeInfo(for: module)
                                SidebarItem(
                                    module:      module,
                                    badge:       info.text,
                                    badgeColor:  info.color,
                                    isEditing:   false
                                )
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // ── Logo header ──────────────────────────────────────────
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
                    // App name + build token / version subtitle
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Halo")
                            .font(HaloFont.display(18, weight: .heavy))
                            .foregroundColor(.haloText)
                        Text(Build.displayLabel)
                            .font(HaloFont.mono(9))
                            .foregroundColor(.haloText3)
                            .help(Build.fullLabel)   // tooltip shows full detail on hover
                    }
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
            }
            .background(Color.haloBackground)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StorageIndicator()
                .padding(12)
                .background(Color.haloBackground)
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
        case .actions:
            let running = ActionRunner.shared.executions.filter { $0.state == .running }.count
            return (running > 0 ? "\(running)" : nil, .haloAmber)
        case .localShare:
            let active = LocalShareManager.shared.activeSessions.count
            return (active > 0 ? "\(active)" : nil, .haloGreen)
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
            // Deliberately NOT wrapped in withAnimation: appState.selectedModule is
            // read by every SidebarItem's `isActive` (and by DetailView's switch), so
            // an implicit-animation transaction here reflows the whole sidebar tree —
            // including the ScrollView around the module list — and macOS SwiftUI
            // resets/re-animates that ScrollView's scroll position as a side effect.
            // The `.animation(value: isActive)` below scopes the highlight transition
            // to just this row instead.
            appState.selectedModule = module
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
            // Without an explicit hit-testing shape, taps over the transparent
            // Spacer/background area pass through instead of selecting the row.
            .contentShape(Rectangle())
            // Scoped to this row's own highlight — see the note in the Button
            // action above for why this replaced a tree-wide withAnimation.
            .animation(.easeInOut(duration: 0.15), value: isActive)
        }
        .buttonStyle(.plain)
        // Clicking a Button normally makes it the key view, and AppKit
        // auto-scrolls any enclosing NSScrollView (including one NavigationSplitView
        // implicitly wraps its sidebar column in) to keep the first responder visible.
        // For a row near the bottom of the list (e.g. AI Assistant), that snapped the
        // WHOLE sidebar — header and all — to a wrong scroll position. Not becoming
        // a focus target at all removes the trigger entirely.
        .focusable(false)
        // Stable UI-test hook: `sidebar.row.<AppModule.rawValue>` (e.g.
        // sidebar.row.performance, sidebar.row.ai). Lets HaloUITests navigate
        // deterministically instead of matching on localized row titles.
        .accessibilityIdentifier("sidebar.row.\(module.rawValue)")
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
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloBorder, lineWidth: 1))
    }
}

// MARK: - Detail Router

struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.haloSurface.ignoresSafeArea()
            switch appState.selectedModule {
            case .dashboard:      DashboardView()
            case .cleanup:        CleanupView()
            case .protection:     ProtectionView()
            case .performance:    PerformanceView()
            case .applications:   ApplicationsView()
            case .files:          FilesView()
            case .clipboard:      ClipboardView()
            case .actions:        ActionsView()
            case .ports:          PortManagerView()
            case .localShare:     LocalShareView()
            case .ai:             AIAssistantView()
            case .menuBarPreview: MenuBarPreviewView()
            }
        }
        .background(Color.haloSurface)
    }
}
