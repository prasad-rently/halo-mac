import SwiftUI
import AppKit

// MARK: - Shared state between controller and SwiftUI view

@MainActor
final class QuickPickerState: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var selectedIndex: Int = 0
}

// MARK: - Panel subclass that always accepts key status and routes Escape

private final class QuickPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onEscape: (() -> Void)?

    // Called by AppKit when Escape is pressed in this window
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

// MARK: - Panel Controller

@MainActor
final class ClipboardQuickPickerController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let state = QuickPickerState()
    var onPaste: ((ClipboardItem) -> Void)?

    func show(allItems: [ClipboardItem]) {
        // Clean up any previous panel/monitor before creating a new one
        removeKeyMonitor()
        panel?.orderOut(nil)
        panel = nil

        state.items = Array(allItems.prefix(9))
        state.selectedIndex = 0
        guard !state.items.isEmpty else { return }

        let rootView = ClipboardQuickPickerView(
            state: state,
            onPaste: { [weak self] item in
                self?.onPaste?(item)
                self?.hide()
            },
            onDismiss: { [weak self] in self?.hide() }
        )

        let hosting = NSHostingController(rootView: rootView)
        let panelH = min(52 * state.items.count + 126, 580)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 540, height: panelH)

        let p = QuickPickerPanel(
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
    }

    func hide() {
        removeKeyMonitor()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible == true }

    // Auto-dismiss when panel loses key status (e.g. user clicks outside)
    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.hide() }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125: // ↓
                self.state.selectedIndex = min(self.state.selectedIndex + 1, self.state.items.count - 1)
                return nil
            case 126: // ↑
                self.state.selectedIndex = max(self.state.selectedIndex - 1, 0)
                return nil
            case 36, 76: // Return / numpad enter
                guard self.state.selectedIndex < self.state.items.count else { return nil }
                let item = self.state.items[self.state.selectedIndex]
                let captured = item
                DispatchQueue.main.async { self.onPaste?(captured); self.hide() }
                return nil
            case 53: // Escape — defer hide() out of the monitor callback to avoid re-entrancy
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

// MARK: - Quick Picker SwiftUI View

struct ClipboardQuickPickerView: View {
    @ObservedObject var state: QuickPickerState
    let onPaste: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader
            Divider().background(Color.haloBorder)
            itemList
            Divider().background(Color.haloBorder)
            pickerFooter
        }
        .background(Color(hex: "#080c14"))
        // Escape dismiss via SwiftUI cancelAction (semantic Escape binding)
        .overlay(
            Button("") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    // MARK: Header

    private var pickerHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.haloAccent.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.haloAccent)
            }
            Text("Clipboard History")
                .font(HaloFont.display(14, weight: .bold))
                .foregroundColor(.haloText)
            Spacer()
            Text("\(state.items.count) items")
                .font(HaloFont.body(11))
                .foregroundColor(.haloText3)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.haloSurface2)
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.haloBorder, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Item list

    private var itemList: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(Array(state.items.enumerated()), id: \.element.id) { idx, item in
                    QuickPickerRow(
                        item: item,
                        index: idx,
                        isSelected: state.selectedIndex == idx
                    ) {
                        onPaste(item)
                    }
                    .onTapGesture {
                        state.selectedIndex = idx
                        onPaste(item)
                    }
                    // ⌘1–⌘9: invisible button for each slot
                    .background(
                        Button("") { onPaste(item) }
                            .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: .command)
                            .opacity(0)
                    )
                }
            }
            .padding(8)
        }
    }

    // MARK: Footer

    private var pickerFooter: some View {
        HStack(spacing: 10) {
            QPHint(key: "↑↓", label: "Navigate")
            QPHint(key: "↵", label: "Paste")
            QPHint(key: "⌘1–9", label: "Quick paste")
            QPHint(key: "⎋", label: "Dismiss")
            Spacer()
            Button("Open App") { onDismiss() }
                .font(HaloFont.body(11))
                .foregroundColor(.haloAccent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Row

struct QuickPickerRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let onPaste: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // ⌘N badge
            Text(index < 9 ? "⌘\(index + 1)" : "")
                .font(HaloFont.mono(10))
                .foregroundColor(isSelected ? .haloAccent : .haloText3)
                .frame(width: 30)
                .padding(.vertical, 3)
                .background(isSelected ? Color.haloAccent.opacity(0.12) : Color.haloSurface2)
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? Color.haloAccent.opacity(0.35) : Color.haloBorder, lineWidth: 1)
                )

            Image(systemName: item.kind.icon)
                .font(.system(size: 13))
                .foregroundColor(item.kind.accentColor)
                .frame(width: 16)

            Text(item.preview)
                .font(item.kind == .code ? HaloFont.mono(12) : HaloFont.body(13))
                .foregroundColor(.haloText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if let app = item.sourceApp {
                Text(app)
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                    .lineLimit(1)
            }

            if isHovered || isSelected {
                Button(action: onPaste) {
                    Text("Paste")
                        .font(HaloFont.body(11, weight: .semibold))
                        .foregroundColor(.haloAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.haloAccent.opacity(0.1))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.haloAccent.opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.haloAccent.opacity(0.08) : isHovered ? Color.haloSurface2 : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? Color.haloAccent.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Hint badge

private struct QPHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(HaloFont.mono(10))
                .foregroundColor(.haloText2)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.haloSurface2)
                .cornerRadius(3)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.haloBorder, lineWidth: 1))
            Text(label)
                .font(HaloFont.body(10))
                .foregroundColor(.haloText3)
        }
    }
}
