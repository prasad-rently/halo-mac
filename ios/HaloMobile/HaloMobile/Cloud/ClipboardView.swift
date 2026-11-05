import SwiftUI
import HaloCloudKit

/// Shared clipboard: explicit, foreground only. Send = the user taps; history = tap to copy.
struct ClipboardView: View {
    @EnvironmentObject var cloud: CloudModel
    @State private var pending: String?
    @State private var purgeAsk = false

    var body: some View {
        NavigationStack {
            Group {
                if !cloud.isPaired {
                    HaloEmptyState(icon: "doc.on.clipboard", title: CloudStrings.setupFirst, subtitle: CloudStrings.worksWhileOpen,
                                   actionTitle: "Open Cloud setup") { cloud.wantsSetup = true }
                } else { content }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).haloScreen()
            .navigationTitle(CloudStrings.clipboard)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HaloInfoSheet(title: CloudStrings.clipboard) {
                        InfoLine(icon: "hand.tap", text: "Nothing is sent unless you tap Send. iOS doesn't allow background clipboard access, so Halo can't watch the clipboard.")
                        InfoLine(icon: "bolt.horizontal", text: "Items from your other devices appear while Halo is open. Tap one to copy it.")
                        InfoLine(icon: "lock", text: "Items are encrypted before they leave this iPhone and kept in memory only here.")
                        Button(role: .destructive) { purgeAsk = true } label: { Label("Clear cloud clipboard", systemImage: "trash") }
                    }
                }
            }
            .sheet(item: Binding(get: { pending.map { Pending(text: $0) } }, set: { pending = $0?.text })) { p in
                SendSheet(text: p.text) { cloud.send(p.text); pending = nil } cancel: { pending = nil }
                    .presentationDetents([.medium])
            }
            .confirmationDialog("Delete every synced clipboard item from your cloud?", isPresented: $purgeAsk, titleVisibility: .visible) {
                Button("Delete from cloud", role: .destructive) { cloud.purgeCloudClipboard() }
                Button(CloudStrings.cancel, role: .cancel) {}
            }
            .toast($cloud.toast)
        }
    }

    private struct Pending: Identifiable { let text: String; var id: String { text } }

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                sendButton
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        HaloChip(text: CloudStrings.worksWhileOpen, icon: "bolt.horizontal")
                        HaloStatusBadge(text: connectionText, level: connectionLevel)
                        if cloud.clipUndecryptable > 0 { HaloChip(text: "\(cloud.clipUndecryptable) locked", icon: "lock.fill", color: .haloAmber) }
                    }
                }
                if cloud.remoteClips.isEmpty && cloud.sentClips.isEmpty {
                    HaloEmptyState(icon: "doc.on.clipboard", title: CloudStrings.noClips, subtitle: CloudStrings.noClipsSub).frame(height: 220)
                }
                ForEach(cloud.sentClips) { s in sentCard(s) }
                ForEach(cloud.remoteClips) { c in clipCard(c) }
            }
            .padding(16)
        }
    }

    /// The system `PasteButton` reads the pasteboard WITHOUT iOS's "Allow Paste" interruption (the tap itself is the
    /// permission), which is exactly the explicit, user-initiated send this screen promises. It is drawn invisibly over
    /// the Halo-styled button so it keeps the app's look.
    private var sendButton: some View {
        ZStack {
            HaloPrimaryButton(title: CloudStrings.sendClipboard, icon: "paperplane.fill") {}.allowsHitTesting(false)
            PasteButton(payloadType: String.self) { strings in
                let text = strings.first ?? ""
                DispatchQueue.main.async {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cloud.toast = CloudStrings.nothingToSend } else { pending = text }
                }
            }
            .labelStyle(.titleOnly)
            .blendMode(.destinationOver)       // invisible but fully tappable
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
            .accessibilityLabel(CloudStrings.sendClipboard)
            .accessibilityIdentifier("clipboard.send")
        }
        .frame(minHeight: 48)
    }

    private var connectionText: String {
        switch cloud.clipConnection { case .live: return "Live"; case .connecting: return "Connecting"; case .offline: return "Offline"; case .failed: return "Problem" }
    }
    private var connectionLevel: HaloStatusBadge.Level {
        switch cloud.clipConnection { case .live: return .good; case .connecting: return .idle; case .offline: return .warn; case .failed: return .bad }
    }

    private func tint(_ kind: String) -> Color { kind == "url" ? Color(hex: "#00d4e8") : (kind == "code" ? Color(hex: "#b06cff") : .haloAccent) }
    private func icon(_ kind: String) -> String { kind == "url" ? "link" : (kind == "code" ? "chevron.left.forwardslash.chevron.right" : "text.alignleft") }

    private func clipCard(_ c: RemoteClip) -> some View {
        let color = tint(c.kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(c.kind)).foregroundColor(color).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.text).font(.system(size: 14, design: c.kind == "code" ? .monospaced : .default)).foregroundColor(.haloText).lineLimit(3).privacySensitive()
                HStack(spacing: 6) {
                    Text(c.deviceName).font(.system(size: 11)).foregroundColor(.haloText3)
                    Text(c.createdAt.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundColor(.haloText3)
                    if ClipboardSensitiveFilter.isSensitive(c.text) { HaloChip(text: "Sensitive", icon: "exclamationmark.shield", color: .haloAmber) }
                }
            }
            Spacer(minLength: 0)
            HaloIconButton(icon: "doc.on.doc", label: "Copy", color: color) { cloud.copy(c) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.haloSurface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.35)))
        .contentShape(Rectangle())
        .onTapGesture { cloud.copy(c) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("clipboard.item")
    }

    private func sentCard(_ s: SentClip) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "paperplane.fill").foregroundColor(.haloGreen).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.text).font(.system(size: 14)).foregroundColor(.haloText).lineLimit(2).privacySensitive()
                Text("\(s.result) · this iPhone").font(.system(size: 11)).foregroundColor(.haloText3)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.haloSurface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloGreen.opacity(0.3)))
        .accessibilityIdentifier("clipboard.sent")
    }
}

private struct SendSheet: View {
    let text: String
    let send: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(CloudStrings.sendThis).font(.system(size: 20, weight: .bold)).foregroundColor(.haloText)
            if ClipboardSensitiveFilter.isSensitive(text) {
                HaloChip(text: CloudStrings.looksSensitive, icon: "exclamationmark.shield.fill", color: .haloAmber)
            }
            ScrollView {
                Text(String(text.prefix(2000))).font(.system(size: 14)).foregroundColor(.haloText2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.haloSurface2)).frame(maxHeight: 180)
            HStack(spacing: 10) {
                Button(CloudStrings.cancel, action: cancel).frame(maxWidth: .infinity, minHeight: 48).foregroundColor(.haloText2)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.haloSurface2))
                HaloPrimaryButton(title: CloudStrings.send, icon: "paperplane.fill", action: send).accessibilityIdentifier("clipboard.confirmSend")
            }
        }
        .padding(20).frame(maxHeight: .infinity, alignment: .top)
        .background(Color.haloBackground.ignoresSafeArea()).preferredColorScheme(.dark)
    }
}
