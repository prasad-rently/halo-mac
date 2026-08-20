import SwiftUI
import AppKit

// MARK: - DriveSearchQuickPickerView  (F-051 FR-16)
//
// Floating panel on ⌘⇧F, mirroring QuickActionPickerController/
// ClipboardQuickPickerView's exact NSPanel pattern (non-activating panel,
// escape-to-dismiss, resign-key-to-dismiss, arrow-key navigation).

private final class DriveSearchPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class DriveSearchQuickPickerController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let state = DriveSearchPickerState()

    func show() {
        removeKeyMonitor()
        panel?.orderOut(nil); panel = nil

        state.query = ""
        state.results = []
        state.selectedIndex = 0

        let hostingView = DriveSearchQuickPickerView(state: state, onDismiss: { [weak self] in self?.hide() })
        let hosting = NSHostingController(rootView: hostingView)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 560, height: 420)

        let p = DriveSearchPickerPanel(
            contentRect: hosting.view.frame,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.backgroundColor = NSColor(calibratedRed: 0.031, green: 0.047, blue: 0.078, alpha: 1)
        p.contentViewController = hosting
        p.delegate = self
        p.onEscape = { [weak self] in self?.hide() }
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
        installKeyMonitor()

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
                self.state.selectedIndex = min(self.state.selectedIndex + 1, max(self.state.results.count - 1, 0))
                return nil
            case 126: // ↑
                self.state.selectedIndex = max(self.state.selectedIndex - 1, 0)
                return nil
            case 36, 76: // ↩ / numpad enter
                guard self.state.selectedIndex < self.state.results.count else { return nil }
                let entry = self.state.results[self.state.selectedIndex]
                DriveIndexCoordinator.shared.openFile(entry)
                DispatchQueue.main.async { self.hide() }
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

// MARK: - Search state

@MainActor
final class DriveSearchPickerState: ObservableObject {
    @Published var query = "" {
        didSet { refresh() }
    }
    @Published var results: [IndexedFileEntry] = []
    @Published var selectedIndex = 0
    private var searchTask: Task<Void, Never>?

    func refresh() {
        searchTask?.cancel()
        let q = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let matches = await DriveIndexCoordinator.shared.search(query: q)
            self.results = matches
            self.selectedIndex = 0
        }
    }
}

// MARK: - SwiftUI view

struct DriveSearchQuickPickerView: View {
    @ObservedObject var state: DriveSearchPickerState
    let onDismiss: () -> Void
    @FocusState private var searchFocused: Bool
    @ObservedObject private var coordinator = DriveIndexCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Divider().background(Color.haloBorder)
            resultsList
        }
        .frame(width: 560)
        .background(Color.haloSurface)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.badge.checkmark").foregroundColor(.haloAccent)
            Text("Search Drives").font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText2)
            Spacer()
            Text("⌘⇧F").font(HaloFont.mono(10)).foregroundColor(.haloText3)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.haloText3)
            TextField("Search files across all drives…", text: $state.query)
                .textFieldStyle(.plain)
                .font(HaloFont.body(15))
                .focused($searchFocused)
                .accessibilityIdentifier("driveIndex.quickSearch.field")
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if state.results.isEmpty {
                    Text(state.query.isEmpty ? "Type to search — even drives that are unplugged." : "No matches.")
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText3)
                        .padding(.vertical, 24)
                } else {
                    ForEach(Array(state.results.enumerated()), id: \.element.id) { index, entry in
                        row(entry, isSelected: index == state.selectedIndex)
                            .onTapGesture {
                                coordinator.openFile(entry)
                                onDismiss()
                            }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 340)
    }

    private func row(_ entry: IndexedFileEntry, isSelected: Bool) -> some View {
        let connected = coordinator.isConnected(driveKey: entry.driveKey)
        return HStack(spacing: 10) {
            Image(systemName: entry.category.icon).foregroundColor(.haloAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName).font(HaloFont.body(13, weight: .medium)).foregroundColor(.haloText)
                Text(entry.relativePath).font(HaloFont.body(11)).foregroundColor(.haloText3).lineLimit(1)
            }
            Spacer()
            HaloBadge(text: connected ? "Connected" : "Disconnected", color: connected ? .haloGreen : .haloText3)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isSelected ? Color.haloSurface2 : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .accessibilityIdentifier("driveIndex.quickSearch.row")
    }
}
