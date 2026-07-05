import SwiftUI

// MARK: - AIAssistantView  (F-046 D5 — sidebar AI module)
//
// Agentic chat over the user's own provider key (Claude in v1). Reads live Mac
// context + runs safe actions via tools; every acting tool pops a confirmation
// sheet (D9). Streaming answers, model picker, BYO-key setup.

struct AIAssistantView: View {
    @StateObject private var vm = AIAssistantViewModel()
    @State private var keyDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.haloBorder)
            if vm.hasKey { chat } else { keySetup }
        }
        .background(Color.haloSurface)
        .sheet(item: $vm.pendingConfirm) { confirmSheet($0) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle").foregroundColor(.haloPurple)
            Text("AI Assistant").font(HaloFont.display(18)).foregroundColor(.haloText)
            HaloBadge(text: "Agentic", color: .haloPurple)
            Spacer()
            if vm.hasKey {
                Picker("", selection: $vm.selectedModelID) {
                    ForEach(vm.claudeModels) { m in Text(m.displayName).tag(m.id) }
                }
                .labelsHidden().frame(width: 170)
                Button { vm.clearConversation() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).foregroundColor(.haloText2).help("New chat")
                Button { vm.clearKey() } label: { Image(systemName: "key.slash") }
                    .buttonStyle(.plain).foregroundColor(.haloText2).help("Remove API key")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Key setup (BYO key, D2)

    private var keySetup: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill").font(.system(size: 34)).foregroundColor(.haloPurple)
            Text("Connect your Claude API key").font(HaloFont.display(16)).foregroundColor(.haloText)
            Text("BYO key — it's stored only in your Mac's Keychain and sent only to Anthropic. Get one at console.anthropic.com.")
                .font(HaloFont.body(12)).foregroundColor(.haloText2)
                .multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            SecureField("sk-ant-…", text: $keyDraft)
                .textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
                .padding(9).frame(width: 320).background(Color.haloSurface2).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
            HaloPrimaryButton("Save key", icon: "checkmark") {
                vm.saveKey(keyDraft); keyDraft = ""
            }.disabled(keyDraft.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if vm.isStreaming {
                Button { vm.stop() } label: {
                    Image(systemName: "stop.fill").foregroundColor(.haloRed)
                }.buttonStyle(.plain)
            } else {
                Button { vm.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        .foregroundColor(vm.input.isEmpty ? .haloText3 : .haloAccent)
                }.buttonStyle(.plain).disabled(vm.input.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
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
