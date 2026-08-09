import SwiftUI

// MARK: - AIAssistantView  (F-046 D5 — sidebar AI module)
//
// Agentic chat over the user's own provider key (Claude in v1). Reads live Mac
// context + runs safe actions via tools; every acting tool pops a confirmation
// sheet (D9). Streaming answers, model picker, BYO-key setup.

struct AIAssistantView: View {
    @StateObject private var vm = AIAssistantViewModel()
    @ObservedObject private var store = ConversationStore.shared
    @State private var keyDraft = ""
    @State private var showHistory = false
    // Defensive: keep the key field from auto-acquiring first responder on
    // appear (doesn't hurt, though the sidebar-scroll bug turned out not to
    // be about focus at all — see the ScrollView note on `keySetup` below).
    @FocusState private var isKeyFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.haloBorder)
            if vm.hasKey { chat } else { keySetup }
        }
        .background(Color.haloSurface)
        .sheet(item: $vm.pendingConfirm) { confirmSheet($0) }
        .sheet(isPresented: $showHistory) { historySheet }
        .onAppear { isKeyFieldFocused = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle").foregroundColor(.haloPurple)
            Text("AI Assistant").font(HaloFont.display(22, weight: .bold)).foregroundColor(.haloText)
            HaloBadge(text: "Agentic", color: .haloPurple)
            Spacer()
            // Provider picker (D10) — only implemented providers.
            Picker("", selection: $vm.selectedProvider) {
                ForEach(vm.providers) { p in Text(p.displayName).tag(p) }
            }
            .labelsHidden().frame(width: 150)
            .accessibilityIdentifier("ai.providerPicker")
            if vm.hasKey {
                Picker("", selection: $vm.selectedModelID) {
                    ForEach(vm.models) { m in Text(m.displayName).tag(m.id) }
                }
                .labelsHidden().frame(width: 150)
                .accessibilityIdentifier("ai.modelPicker")
                Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.plain).foregroundColor(.haloText2).help("Conversation history")
                Button { vm.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).foregroundColor(.haloText2).help("New chat")
                Button { vm.clearKey() } label: { Image(systemName: "key.slash") }
                    .buttonStyle(.plain).foregroundColor(.haloText2).help("Remove API key")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Key setup (BYO key, D2)

    private var keyPlaceholder: String {
        switch vm.selectedProvider {
        case .openai: return "sk-…"
        case .gemini: return "AIza…"
        case .claude: return "sk-ant-…"
        }
    }

    // Wrapped in a ScrollView so this pane's root reports the same kind of
    // bounded/scrollable size every other module's detail view does (Dashboard,
    // Performance, HaloShare, etc. all root themselves in a ScrollView). This
    // used to be a bare VStack with a maxHeight:.infinity child — an unboundedly
    // flexible size NavigationSplitView doesn't see from any other detail view —
    // and was the actual cause of the sidebar column mis-laying-out (not focus,
    // not the sidebar's own List/ScrollView code, which is why every fix aimed
    // at SidebarView itself had no effect).
    private var keySetup: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "key.fill").font(.system(size: 34)).foregroundColor(.haloPurple)
                Text("Connect your \(vm.selectedProvider.displayName) API key")
                    .font(HaloFont.display(16)).foregroundColor(.haloText)
                    .accessibilityIdentifier("ai.keySetup.title")
                Text("BYO key — stored only in your Mac's Keychain and sent only to \(vm.selectedProvider.displayName). Each provider has its own key.")
                    .font(HaloFont.body(12)).foregroundColor(.haloText2)
                    .multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
                SecureField(keyPlaceholder, text: $keyDraft)
                    .textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
                    .padding(9).frame(width: 320).background(Color.haloSurface2).cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
                    .focused($isKeyFieldFocused)
                HaloPrimaryButton("Save key", icon: "checkmark") {
                    vm.saveKey(keyDraft); keyDraft = ""
                }.disabled(keyDraft.isEmpty)
            }
            .frame(maxWidth: .infinity, minHeight: 460)
            .padding(.top, 100)
        }
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if vm.items.isEmpty { emptyState }
                        ForEach(vm.items) { row($0) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(18)
                }
                .onChange(of: vm.items) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            Divider().background(Color.haloBorder)
            inputBar
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about your Mac").font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
            ForEach(["Why is my Mac slow right now?", "How much disk space is left?",
                     "Run a smart scan and export a report"], id: \.self) { s in
                Button { vm.input = s } label: {
                    Text("“\(s)”").font(HaloFont.body(12)).foregroundColor(.haloAccent)
                }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
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
            }.padding(10).background(Color.haloRed.opacity(0.1)).cornerRadius(8)
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text).font(HaloFont.body(13)).foregroundColor(.haloText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(11)
                .background(mine ? Color.haloAccent.opacity(0.18) : Color.haloSurface2)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: mine ? 0 : 1))
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
                    Text(item.text).font(HaloFont.body(11)).foregroundColor(.haloText3).lineLimit(4)
                }
            }
            Spacer()
        }
        .padding(9).background(Color.haloSurface2.opacity(0.5)).cornerRadius(8)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask Halo…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.plain).font(HaloFont.body(13)).foregroundColor(.haloText)
                .lineLimit(1...5)
                .onSubmit { vm.send() }
                .padding(10).background(Color.haloSurface2).cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
                .accessibilityIdentifier("ai.composer")
            if vm.isStreaming {
                Button { vm.stop() } label: {
                    Image(systemName: "stop.fill").foregroundColor(.haloRed)
                }.buttonStyle(.plain)
                .accessibilityIdentifier("ai.stop.button")
            } else {
                Button { vm.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        .foregroundColor(vm.input.isEmpty ? .haloText3 : .haloAccent)
                }.buttonStyle(.plain).disabled(vm.input.isEmpty)
                .accessibilityIdentifier("ai.send.button")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: History (D11 — saved conversations, privacy surface)

    private static func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations").font(HaloFont.display(16)).foregroundColor(.haloText)
                Spacer()
                if !store.conversations.isEmpty {
                    Button("Clear all", role: .destructive) { store.clearAll() }
                        .buttonStyle(.plain).font(HaloFont.body(11)).foregroundColor(.haloRed)
                }
                Button { showHistory = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundColor(.haloText3)
            }
            .padding(16)
            Divider().background(Color.haloBorder)
            if store.conversations.isEmpty {
                Text("No saved conversations yet.")
                    .font(HaloFont.body(12)).foregroundColor(.haloText2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.conversations) { c in
                            HStack(spacing: 10) {
                                Button { vm.load(c); showHistory = false } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.title).font(HaloFont.body(12, weight: .semibold))
                                            .foregroundColor(.haloText).lineLimit(1)
                                        Text("\(c.turns.count) messages · \(Self.relativeDate(c.updatedAt))")
                                            .font(HaloFont.body(10)).foregroundColor(.haloText3)
                                    }
                                    Spacer()
                                }.buttonStyle(.plain)
                                Button { vm.deleteSaved(id: c.id) } label: {
                                    Image(systemName: "trash").foregroundColor(.haloRed)
                                }.buttonStyle(.plain)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 440, height: 380).background(Color.haloSurface)
    }

    // MARK: Confirmation sheet (D9)

    private func confirmSheet(_ p: AIAssistantViewModel.PendingConfirm) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundColor(.haloAmber)
                Text("Run this action?").font(HaloFont.display(16)).foregroundColor(.haloText)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(p.toolName).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloAccent)
                Text(p.description).font(HaloFont.body(12)).foregroundColor(.haloText2)
                    .fixedSize(horizontal: false, vertical: true)
                if p.inputJSON != "{}" && !p.inputJSON.isEmpty {
                    Text(p.inputJSON).font(HaloFont.mono(11)).foregroundColor(.haloText3)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.haloSurface2).cornerRadius(6)
                }
            }
            Text("The assistant proposed this. It only runs if you approve.")
                .font(HaloFont.body(11)).foregroundColor(.haloText3)
            HStack(spacing: 12) {
                HaloGhostButton("Decline") { vm.resolveConfirm(false) }
                Spacer()
                HaloPrimaryButton("Approve & run", icon: "checkmark") { vm.resolveConfirm(true) }
            }
        }
        .padding(22).frame(width: 420).background(Color.haloSurface)
    }
}
