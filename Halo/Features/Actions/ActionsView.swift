import SwiftUI

// MARK: - ActionsView

struct ActionsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var library = ActionLibrary.shared
    @ObservedObject private var runner  = ActionRunner.shared
    @StateObject    private var vm      = ActionsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                quickActionsHeader
                systemControlsStrip     // Mic mute + Camera status always at top
                predefinedGrid
                if !runner.executions.isEmpty {
                    recentSection
                }
                customActionsSection
            }
            .padding(24)
        }
        .background(Color.haloSurface)
        .sheet(isPresented: $vm.showEditor) {
            CustomActionEditor(
                mode:     vm.editorMode,
                onSave:   { vm.saveAction($0) },
                onCancel: { vm.showEditor = false }
            )
        }
        .alert("Delete Action", isPresented: $vm.showDeleteConfirm) {
            Button("Delete", role: .destructive) { vm.confirmDelete() }
            Button("Cancel", role: .cancel)      { }
        } message: {
            Text("\"\(vm.actionToDelete?.name ?? "")\" will be permanently removed.")
        }
    }

    // MARK: - System Controls Strip (mic + camera + screen, always pinned at top)

    private var systemControlsStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mic & Camera Controls", systemImage: "lock.shield.fill")
                    .font(HaloFont.body(10, weight: .semibold))
                    .foregroundColor(.haloText3)
                Spacer()
                Text("⌘⇧A · Menu Bar · here")
                    .font(HaloFont.body(9))
                    .foregroundColor(.haloText3)
            }
            MicCameraControlsView(compact: false)
        }
    }

    // MARK: - Header

    private var quickActionsHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quick Actions")
                    .font(HaloFont.display(22, weight: .heavy))
                    .foregroundColor(.haloText)
                Text("Run common tasks instantly · ⌘⇧A to invoke from anywhere")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText3)
            }
            Spacer()
            Button {
                vm.editorMode  = .create
                vm.showEditor  = true
            } label: {
                Label("New Action", systemImage: "plus")
                    .font(HaloFont.body(13, weight: .semibold))
                    .foregroundColor(.haloAccent)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.haloAccent.opacity(0.1))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloAccent.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Predefined tiles grid

    private var predefinedGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ActionCategory.allCases) { cat in
                let catActions = library.actions.filter { $0.category == cat }
                if !catActions.isEmpty {
                    categorySection(cat, actions: catActions)
                }
            }
        }
    }

    private func categorySection(_ cat: ActionCategory, actions: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: cat.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(cat.color)
                Text(cat.rawValue.uppercased())
                    .font(HaloFont.body(10, weight: .semibold))
                    .foregroundColor(.haloText3)
                    .tracking(1.2)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 10)],
                spacing: 10
            ) {
                ForEach(actions) { action in
                    ActionTile(action: action) {
                        runner.run(action, appState: appState)
                    } onEdit: {
                        vm.editorMode = .edit(action)
                        vm.showEditor = true
                    } onDelete: {
                        vm.requestDelete(action)
                    } onPin: {
                        library.togglePin(action)
                    }
                }
            }
        }
    }

    // MARK: - Recent executions

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Runs")
                    .font(HaloFont.body(13, weight: .semibold))
                    .foregroundColor(.haloText2)
                Spacer()
                Button("Clear") { runner.clearHistory() }
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText3)
                    .buttonStyle(.plain)
            }
            VStack(spacing: 6) {
                ForEach(runner.executions.prefix(8)) { exec in
                    ExecutionRow(execution: exec)
                }
            }
        }
    }

    // MARK: - Custom actions section

    private var customActionsSection: some View {
        let customs = library.actions.filter { !$0.isBuiltIn }
        return Group {
            if !customs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("MY CUSTOM ACTIONS")
                        .font(HaloFont.body(10, weight: .semibold))
                        .foregroundColor(.haloText3)
                        .tracking(1.2)
                    VStack(spacing: 6) {
                        ForEach(customs) { action in
                            CustomActionRow(action: action) {
                                runner.run(action, appState: appState)
                            } onEdit: {
                                vm.editorMode = .edit(action)
                                vm.showEditor = true
                            } onDelete: {
                                vm.requestDelete(action)
                            }
                        }
                    }
                }
            } else {
                emptyCustomState
            }
        }
    }

    private var emptyCustomState: some View {
        HaloCard {
            VStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.haloText3)
                Text("No Custom Actions Yet")
                    .font(HaloFont.body(14, weight: .semibold))
                    .foregroundColor(.haloText2)
                Text("Create a custom action to run any shell command or script — remove node_modules, trigger project builds, archive apps, and more.")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText3)
                    .multilineTextAlignment(.center)
                Button {
                    vm.editorMode = .create
                    vm.showEditor = true
                } label: {
                    Label("Create First Action", systemImage: "plus.circle.fill")
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(LinearGradient(colors: [.haloAccent, .haloAccent2],
                                                   startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(9)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }
}

// MARK: - Action Tile

private struct ActionTile: View {
    let action:   ActionItem
    let onRun:    () -> Void
    let onEdit:   () -> Void
    let onDelete: () -> Void
    let onPin:    () -> Void
    @State private var isHovered  = false
    @State private var justRan    = false

    var body: some View {
        HaloCard {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(action.iconColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: action.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(action.iconColor)
                }
                // Text
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(action.name)
                            .font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.haloText)
                        if action.requiresPrivilege {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.haloAmber)
                        }
                        if action.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.haloAccent)
                        }
                    }
                    Text(action.subtitle)
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText3)
                        .lineLimit(1)
                }
                Spacer()
                // Run button
                Button(action: {
                    justRan = true
                    onRun()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justRan = false }
                }) {
                    Image(systemName: justRan ? "checkmark.circle.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundColor(justRan ? .haloGreen : action.iconColor)
                        .frame(width: 30, height: 30)
                        .background(action.iconColor.opacity(0.1))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: justRan)
            }
            .padding(14)
            // Context menu
            .contextMenu {
                Button { onRun() } label: {
                    Label("Run", systemImage: "play.fill")
                }
                Button { onPin() } label: {
                    Label(action.isPinned ? "Unpin" : "Pin to Top",
                          systemImage: action.isPinned ? "pin.slash" : "pin.fill")
                }
                if !action.isBuiltIn {
                    Divider()
                    Button { onEdit() } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .onHover { isHovered = $0 }
        .opacity(isHovered ? 0.9 : 1)
    }
}

// MARK: - Indeterminate progress bar (sweeping amber segment)

private struct IndeterminateBar: View {
    @State private var position: Double = -0.4   // starts off-screen left

    var body: some View {
        GeometryReader { geo in
            Color.haloAmber.opacity(0.75)
                .frame(width: geo.size.width * 0.38, height: 3)
                .offset(x: position * geo.size.width)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 1.1)
                        .repeatForever(autoreverses: true)
                    ) { position = 0.62 }
                }
        }
        .frame(height: 3)
        .background(Color.haloSurface2)
        .clipped()
    }
}

// MARK: - Execution Row

struct ExecutionRow: View {
    let execution: ActionExecution
    @State private var expanded = false

    var body: some View {
        HaloCard {
            VStack(spacing: 0) {
                // Summary row
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(hex: execution.actionIconColor).opacity(0.15))
                            .frame(width: 30, height: 30)
                        if execution.state == .running {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.55)
                        } else {
                            Image(systemName: execution.state.icon)
                                .font(.system(size: 13))
                                .foregroundColor(execution.state.color)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(execution.actionName)
                            .font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.haloText)
                        if execution.state == .running {
                            Text(execution.lastOutputLine.isEmpty
                                 ? "Running…"
                                 : execution.lastOutputLine)
                                .font(HaloFont.mono(10))
                                .foregroundColor(.haloAmber)
                                .lineLimit(1)
                        } else {
                            Text(execution.state.label)
                                .font(HaloFont.body(11))
                                .foregroundColor(execution.state.color)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(execution.duration)
                            .font(HaloFont.mono(10))
                            .foregroundColor(.haloText3)
                        Text(execution.startDate, style: .time)
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloText3)
                    }
                    // Expand/collapse output
                    if !execution.outputLines.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                        } label: {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11))
                                .foregroundColor(.haloText3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)

                // Progress bar (shown while running and for 0.5 s after completion)
                if execution.state == .running {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.haloSurface2.frame(height: 3)
                            if execution.progress < 0 {
                                // Indeterminate — sweeping bar managed by IndeterminateBar
                                IndeterminateBar()
                            } else {
                                Color.haloGreen
                                    .frame(width: geo.size.width * execution.progress, height: 3)
                                    .animation(.linear(duration: 0.3), value: execution.progress)
                            }
                        }
                    }
                    .frame(height: 3)
                }

                // Expanded output log
                if expanded && !execution.outputLines.isEmpty {
                    Divider().background(Color.haloBorder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(execution.outputLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(HaloFont.mono(11))
                                    .foregroundColor(line.hasPrefix("⚠") ? .haloAmber
                                                     : line.hasPrefix("✓") ? .haloGreen
                                                     : .haloText2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 160)
                    .background(Color.haloSurface2)
                }
            }
        }
    }
}

// MARK: - Custom Action Row

private struct CustomActionRow: View {
    let action:   ActionItem
    let onRun:    () -> Void
    let onEdit:   () -> Void
    let onDelete: () -> Void

    var body: some View {
        HaloCard {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(action.iconColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: action.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(action.iconColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.name)
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(.haloText)
                    if !action.subtitle.isEmpty {
                        Text(action.subtitle)
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if action.requiresPrivilege {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.haloAmber)
                }
                HStack(spacing: 6) {
                    iconBtn("play.fill",   color: action.iconColor, action: onRun)
                    iconBtn("pencil",      color: .haloText3,       action: onEdit)
                    iconBtn("trash",       color: .haloRed,         action: onDelete)
                }
            }
            .padding(12)
        }
    }

    private func iconBtn(_ sym: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sym)
                .font(.system(size: 11))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.08))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ViewModel

@MainActor
final class ActionsViewModel: ObservableObject {
    @Published var showEditor         = false
    @Published var showDeleteConfirm  = false
    @Published var editorMode:  CustomActionEditor.Mode = .create
    @Published var actionToDelete: ActionItem?

    func saveAction(_ action: ActionItem) {
        if case .edit = editorMode {
            ActionLibrary.shared.update(action)
        } else {
            ActionLibrary.shared.add(custom: action)
        }
        showEditor = false
    }

    func requestDelete(_ action: ActionItem) {
        actionToDelete     = action
        showDeleteConfirm  = true
    }

    func confirmDelete() {
        if let a = actionToDelete { ActionLibrary.shared.delete(a) }
        actionToDelete = nil
    }
}
