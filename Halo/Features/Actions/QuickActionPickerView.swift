import SwiftUI
import AppKit

// MARK: - Shared state

@MainActor
final class QuickActionPickerState: ObservableObject {
    @Published var query:         String       = ""
    @Published var results:       [ActionItem] = []
    @Published var selectedIndex: Int          = 0

    func refresh() {
        results = ActionLibrary.shared.search(query: query)
        selectedIndex = 0
    }
}

// MARK: - Panel subclass

private final class ActionPickerPanel: NSPanel {
    override var canBecomeKey:  Bool { true  }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Panel Controller

@MainActor
final class QuickActionPickerController: NSObject, NSWindowDelegate {

    private var panel:      NSPanel?
    private var keyMonitor: Any?
    let state = QuickActionPickerState()
    var onRun: ((ActionItem) -> Void)?

    func show() {
        removeKeyMonitor()
        panel?.orderOut(nil); panel = nil

        state.query = ""
        state.refresh()

        let hostingView = QuickActionPickerView(
            state:     state,
            onRun:     { [weak self] item in self?.onRun?(item); self?.hide() },
            onDismiss: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingController(rootView: hostingView)
        let height  = min(52 * max(state.results.count, 1) + 120, 520)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 580, height: height)

        let p = ActionPickerPanel(
            contentRect: hosting.view.frame,
            styleMask:   [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.level                        = .floating
        p.titleVisibility              = .hidden
        p.titlebarAppearsTransparent   = true
        p.isMovableByWindowBackground  = true
        p.backgroundColor              = NSColor(calibratedRed: 0.031, green: 0.047, blue: 0.078, alpha: 1)
        p.contentViewController        = hosting
        p.delegate                     = self
        p.onEscape = { [weak self] in self?.hide() }
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
        installKeyMonitor()

        // Drive focus into the SwiftUI TextField a tick after the window is on screen.
        // NSHostingController wraps the view in a standard NSView hierarchy; making
        // the hosting controller's view first responder triggers @FocusState propagation.
        DispatchQueue.main.async {
            hosting.view.window?.makeFirstResponder(hosting.view)
        }
    }

    func hide() {
        removeKeyMonitor()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible == true }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.hide() }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125: // ↓
                self.state.selectedIndex = min(self.state.selectedIndex + 1,
                                               max(self.state.results.count - 1, 0))
                return nil
            case 126: // ↑
                self.state.selectedIndex = max(self.state.selectedIndex - 1, 0)
                return nil
            case 36, 76: // ↩ / numpad enter
                guard self.state.selectedIndex < self.state.results.count else { return nil }
                let item = self.state.results[self.state.selectedIndex]
                DispatchQueue.main.async { self.onRun?(item); self.hide() }
                return nil
            case 53: // Esc
                DispatchQueue.main.async { self.hide() }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

// MARK: - SwiftUI View

struct QuickActionPickerView: View {
    @ObservedObject var state:    QuickActionPickerState
    let onRun:     (ActionItem) -> Void
    let onDismiss: () -> Void

    /// Drives cursor focus into the search TextField automatically on appear.
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Divider().background(Color.haloBorder)
            resultList
            Divider().background(Color.haloBorder)
            footer
        }
        .background(Color(hex: "#080c14"))
        .overlay(
            Button("") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0)
        )
        // Activate cursor in the search field as soon as the panel appears
        .onAppear { searchFocused = true }
    }

    // MARK: Sub-views

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.haloAccent.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.haloAccent)
            }
            Text("Quick Actions")
                .font(HaloFont.display(14, weight: .bold))
                .foregroundColor(.haloText)
            Spacer()
            Text("\(state.results.count) actions")
                .font(HaloFont.body(11))
                .foregroundColor(.haloText3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.haloSurface2)
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.haloBorder, lineWidth: 1))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.haloText3)
                .font(.system(size: 14))
            TextField("Type an action… (e.g. clear xcode, flush dns, speed test)", text: $state.query)
                .textFieldStyle(.plain)
                .font(HaloFont.body(14))
                .foregroundColor(.haloText)
                .focused($searchFocused)
                .onChange(of: state.query) { _ in state.refresh() }
            if !state.query.isEmpty {
                Button { state.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.haloText3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var resultList: some View {
        ScrollView {
            VStack(spacing: 3) {
                if state.results.isEmpty {
                    HStack {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.haloText3)
                        Text("No actions match \"\(state.query)\"")
                            .font(HaloFont.body(13))
                            .foregroundColor(.haloText3)
                    }
                    .padding(24)
                } else {
                    ForEach(Array(state.results.enumerated()), id: \.element.id) { idx, action in
                        ActionPickerRow(
                            action:     action,
                            index:      idx,
                            isSelected: state.selectedIndex == idx,
                            onRun:      { onRun(action) }
                        )
                        .onTapGesture { state.selectedIndex = idx; onRun(action) }
                        .onHover      { if $0 { state.selectedIndex = idx } }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(maxHeight: 360)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            QPAHint(key: "↑↓", label: "Navigate")
            QPAHint(key: "↵",  label: "Run")
            QPAHint(key: "⎋",  label: "Dismiss")
            Spacer()
            Text("⌘⇧A to invoke anytime")
                .font(HaloFont.body(10))
                .foregroundColor(.haloText3)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Row

private struct ActionPickerRow: View {
    let action:     ActionItem
    let index:      Int
    let isSelected: Bool
    let onRun:      () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon tile
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(action.iconColor.opacity(isSelected ? 0.25 : 0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: action.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(action.iconColor)
            }
            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                    .font(HaloFont.body(13, weight: .semibold))
                    .foregroundColor(isSelected ? .haloText : .haloText2)
                Text(action.subtitle)
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText3)
                    .lineLimit(1)
            }
            Spacer()
            // Category badge
            Text(action.category.rawValue)
                .font(HaloFont.body(10))
                .foregroundColor(action.category.color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(action.category.color.opacity(0.1))
                .cornerRadius(5)
            // Privilege badge
            if action.requiresPrivilege {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.haloAmber)
            }
            if isHovered || isSelected {
                Button(action: onRun) {
                    Text("Run")
                        .font(HaloFont.body(11, weight: .semibold))
                        .foregroundColor(action.iconColor)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(action.iconColor.opacity(0.1))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(action.iconColor.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.haloAccent.opacity(0.08) : isHovered ? Color.haloSurface2 : .clear)
        )
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(isSelected ? Color.haloAccent.opacity(0.2) : .clear, lineWidth: 1))
        .onHover { isHovered = $0 }
    }
}

// MARK: - Hint badge

private struct QPAHint: View {
    let key: String; let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(HaloFont.mono(10)).foregroundColor(.haloText2)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.haloSurface2).cornerRadius(3)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.haloBorder, lineWidth: 1))
            Text(label).font(HaloFont.body(10)).foregroundColor(.haloText3)
        }
    }
}
