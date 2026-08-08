import SwiftUI
import AppKit

// MARK: - AIQuickAskView  (F-046 D5 — second AI surface)
//
// The ⌘⇧I floating quick-ask overlay. Same DNA as the ⌘⇧V clipboard picker and
// ⌘⇧A action picker: a non-activating `NSPanel` that appears centred, focuses an
// input field, and dismisses on Esc / click-away. Unlike those pickers it hosts
// a full `AIAssistantViewModel`, so the agent loop, live read-tools, streaming,
// per-turn persistence (D11) and the D9 confirmation gate all work — the
// confirmation is rendered inline (no separate sheet window, which would steal
// key focus and dismiss the panel).

// MARK: - Panel subclass

private final class AIQuickAskPanel: NSPanel {
    override var canBecomeKey:  Bool { true  }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Panel Controller

@MainActor
final class AIQuickAskController: NSObject, NSWindowDelegate {

    private var panel:      NSPanel?
    private var keyMonitor: Any?
    /// One long-lived VM so a quick-ask thread survives dismiss/reopen (a "New"
    /// button clears it). Reuses the same agent stack as the sidebar module.
    let vm = AIAssistantViewModel()

    func toggle() { isVisible ? hide() : show() }

    func show() {
        // If already on screen just re-focus it.
        if let p = panel, p.isVisible { p.makeKeyAndOrderFront(nil); return }
        removeKeyMonitor()
        panel?.orderOut(nil); panel = nil

        vm.input = ""

        let root = AIQuickAskView(
            vm:        vm,
            onDismiss: { [weak self] in self?.hide() },
            onOpenModule: { [weak self] in self?.openModule() }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 580, height: 460)

        let p = AIQuickAskPanel(
            contentRect: hosting.view.frame,
            styleMask:   [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.level                       = .floating
        p.titleVisibility             = .hidden
        p.titlebarAppearsTransparent  = true
        p.isMovableByWindowBackground = true
        p.backgroundColor             = NSColor(Color.haloBackground)   // token, not a hand-converted hex
        p.contentViewController       = hosting
        p.delegate                    = self
        p.onEscape = { [weak self] in self?.hide() }
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
        installKeyMonitor()

        DispatchQueue.main.async {
            hosting.view.window?.makeFirstResponder(hosting.view)
        }
    }

    func hide() {
        removeKeyMonitor()
        // Cancelling an in-flight run also declines any pending confirmation (D9).
        if vm.isStreaming || vm.pendingConfirm != nil { vm.stop() }
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Bring the user into the full sidebar AI module (e.g. to add a key).
    private func openModule() {
        hide()
        AppState.shared?.selectedModule = .ai
        NSApp.activate(ignoringOtherApps: true)
        // Surface the main window if the app is running menu-bar-only.
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        // Don't dismiss while a confirmation is pending — the user needs to decide.
        Task { @MainActor in
            guard self.vm.pendingConfirm == nil else { return }
            self.hide()
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                DispatchQueue.main.async { self.hide() }
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

// MARK: - SwiftUI View

struct AIQuickAskView: View {
    @ObservedObject var vm: AIAssistantViewModel
    let onDismiss:    () -> Void
    let onOpenModule: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var keyDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.haloBorder)
            if vm.hasKey { conversation } else { keySetup }
        }
        .background(Color.haloBackground)
        .overlay(
            Button("") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.haloPurple.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkle")
                    .font(.system(size: 13))
                    .foregroundColor(.haloPurple)
            }
            Text("Ask Halo AI")
                .font(HaloFont.display(14, weight: .bold))
                .foregroundColor(.haloText)
            Spacer()
            if vm.hasKey {
                Picker("", selection: $vm.selectedProvider) {
                    ForEach(vm.providers) { p in Text(p.displayName).tag(p) }
                }
                .labelsHidden().frame(width: 130)
                Button { vm.newChat(); vm.input = ""; inputFocused = true } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain).foregroundColor(.haloText2).help("New quick-ask")
                Button { onOpenModule() } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain).foregroundColor(.haloText2).help("Open full AI module")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if vm.items.isEmpty { emptyState }
                        ForEach(vm.items) { row($0) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: vm.items) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            if let confirm = vm.pendingConfirm { confirmBar(confirm) }
            Divider().background(Color.haloBorder)
            inputBar
            footer
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about your Mac — the assistant reads live data.")
                .font(HaloFont.body(12)).foregroundColor(.haloText2)
            ForEach(["Why is my Mac slow right now?",
                     "How much disk space is left?",
                     "Run a smart scan"], id: \.self) { s in
                Button { vm.input = s; vm.send() } label: {
                    Text("“\(s)”").font(HaloFont.body(12)).foregroundColor(.haloAccent)
                }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    @ViewBuilder private func row(_ item: AIAssistantViewModel.ChatItem) -> some View {
        switch item.kind {
        case .user:      bubble(item.text, mine: true)
        case .assistant: bubble(item.text.isEmpty ? "…" : item.text, mine: false)
        case .tool:      toolRow(item)
        case .error:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.haloRed)
                Text(item.text).font(HaloFont.body(11)).foregroundColor(.haloRed)
            }.padding(9).background(Color.haloRed.opacity(0.1)).cornerRadius(8)
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text).font(HaloFont.body(13)).foregroundColor(.haloText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(mine ? Color.haloAccent.opacity(0.18) : Color.haloSurface2)
                .cornerRadius(11)
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.haloBorder, lineWidth: mine ? 0 : 1))
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func toolRow(_ item: AIAssistantViewModel.ChatItem) -> some View {
        let (icon, color): (String, Color) = {
            switch item.toolStatus {
            case .done:   return ("checkmark.circle.fill", .haloGreen)
            case .denied: return ("minus.circle.fill", .haloAmber)
            case .failed: return ("xmark.octagon.fill", .haloRed)
            default:      return ("gearshape.2.fill", .haloText2)
            }
        }()
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.toolName ?? "tool").font(HaloFont.body(11, weight: .semibold)).foregroundColor(.haloText2)
                if !item.text.isEmpty {
                    Text(item.text).font(HaloFont.body(11)).foregroundColor(.haloText3).lineLimit(3)
                }
            }
            Spacer()
        }
        .padding(8).background(Color.haloSurface2.opacity(0.5)).cornerRadius(8)
    }

    // MARK: Inline confirmation (D9 — no sheet, keeps panel key)

    private func confirmBar(_ p: AIAssistantViewModel.PendingConfirm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundColor(.haloAmber)
                Text("Run \(p.toolName)?")
                    .font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText)
            }
            Text(p.description).font(HaloFont.body(11)).foregroundColor(.haloText2)
                .fixedSize(horizontal: false, vertical: true)
            if p.inputJSON != "{}" && !p.inputJSON.isEmpty {
                Text(p.inputJSON).font(HaloFont.mono(10)).foregroundColor(.haloText3)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.haloSurface2).cornerRadius(5)
            }
            HStack(spacing: 10) {
                HaloGhostButton("Decline") { vm.resolveConfirm(false) }
                Spacer()
                HaloPrimaryButton("Approve & run", icon: "checkmark") { vm.resolveConfirm(true) }
            }
        }
        .padding(12)
        .background(Color.haloAmber.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundColor(.haloBorder), alignment: .top)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(.haloText3).font(.system(size: 13))
            TextField("Ask Halo…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.plain).font(HaloFont.body(13)).foregroundColor(.haloText)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { vm.send() }
            if vm.isStreaming {
                Button { vm.stop() } label: {
                    Image(systemName: "stop.fill").foregroundColor(.haloRed)
                }.buttonStyle(.plain)
            } else {
                Button { vm.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        .foregroundColor(vm.input.isEmpty ? .haloText3 : .haloAccent)
                }.buttonStyle(.plain).disabled(vm.input.isEmpty)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .onAppear { inputFocused = true }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            QAHint(key: "↵",  label: "Ask")
            QAHint(key: "⎋",  label: "Dismiss")
            Spacer()
            Text("⌘⇧I to invoke anytime")
                .font(HaloFont.body(10)).foregroundColor(.haloText3)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: Key setup (BYO key, D2 — inline so the overlay is self-sufficient)

    private var keyPlaceholder: String {
        switch vm.selectedProvider {
        case .openai: return "sk-…"
        case .gemini: return "AIza…"
        case .claude: return "sk-ant-…"
        }
    }

    private var keySetup: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill").font(.system(size: 28)).foregroundColor(.haloPurple)
            Text("Connect your \(vm.selectedProvider.displayName) API key")
                .font(HaloFont.display(14)).foregroundColor(.haloText)
            Text("Stored only in your Mac's Keychain, sent only to the provider.")
                .font(HaloFont.body(11)).foregroundColor(.haloText2)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Picker("", selection: $vm.selectedProvider) {
                ForEach(vm.providers) { p in Text(p.displayName).tag(p) }
            }
            .labelsHidden().frame(width: 180)
            SecureField(keyPlaceholder, text: $keyDraft)
                .textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
                .padding(9).frame(width: 300).background(Color.haloSurface2).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
                .onSubmit { saveKey() }
            HaloPrimaryButton("Save key", icon: "checkmark") { saveKey() }
                .disabled(keyDraft.isEmpty)
            Button { onOpenModule() } label: {
                Text("Open full AI module").font(HaloFont.body(11)).foregroundColor(.haloAccent)
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func saveKey() {
        guard !keyDraft.isEmpty else { return }
        vm.saveKey(keyDraft); keyDraft = ""
        inputFocused = true
    }
}

// MARK: - Hint badge

private struct QAHint: View {
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
