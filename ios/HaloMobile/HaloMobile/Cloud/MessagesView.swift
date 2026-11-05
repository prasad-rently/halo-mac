import SwiftUI
import HaloCloudKit

/// The SMS viewer. iOS has no SMS read API, so this only ever shows what the Android phone synced — read-only.
struct MessagesView: View {
    @EnvironmentObject var cloud: CloudModel
    @State private var query = ""
    @State private var lineFilter: String?          // SMSLine.id, nil = all

    var body: some View {
        NavigationStack {
            Group {
                if !cloud.isPaired {
                    HaloEmptyState(icon: "message", title: CloudStrings.setupFirst, subtitle: CloudStrings.viewerOnly,
                                   actionTitle: "Open Cloud setup") { cloud.wantsSetup = true }
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).haloScreen()
            .navigationTitle(CloudStrings.messages)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HaloInfoSheet(title: CloudStrings.messages) {
                        InfoLine(icon: "eye", text: "Viewer only. iOS doesn't let apps read SMS, so this shows messages synced from your Android phone.")
                        InfoLine(icon: "lock", text: "Messages are decrypted on this iPhone and kept in memory only. They are not saved to disk.")
                        InfoLine(icon: "bolt.horizontal", text: "Updates while Halo is open.")
                    }
                }
            }
            .navigationDestination(for: SMSThread.self) { ConversationView(threadID: $0.id) }
        }
    }

    private var filtered: [SMSThread] {
        cloud.threads.filter { t in
            (lineFilter == nil || t.lineId == lineFilter) &&
            (query.isEmpty || t.contact.localizedCaseInsensitiveContains(query) || t.messages.contains { $0.body.localizedCaseInsensitiveContains(query) })
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            chips
            if filtered.isEmpty {
                HaloEmptyState(icon: "tray", title: cloud.threads.isEmpty ? CloudStrings.noMessages : "No matches",
                               subtitle: cloud.threads.isEmpty ? CloudStrings.noMessagesSub : nil)
            } else {
                List(filtered) { t in
                    NavigationLink(value: t) { ThreadRow(thread: t, line: cloud.line(t.lineId)) }
                        .listRowBackground(Color.haloBackground)
                        .listRowSeparatorTint(Color.haloBorder)
                        .accessibilityIdentifier("messages.thread.\(t.contact)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $query, prompt: CloudStrings.searchMessages)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HaloChip(text: CloudStrings.viewerOnly, icon: "eye", color: .haloText2)
                if cloud.sms.undecryptableCount > 0 {
                    HaloChip(text: "\(cloud.sms.undecryptableCount) locked", icon: "lock.fill", color: .haloAmber)
                }
                filterChip("All", id: nil)
                ForEach(cloud.lines) { l in filterChip(l.label, id: l.id) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func filterChip(_ title: String, id: String?) -> some View {
        Button { lineFilter = id } label: {
            HaloChip(text: title, color: lineFilter == id ? .haloAccent : .haloText3).frame(minHeight: 44)
        }
        .accessibilityAddTraits(lineFilter == id ? .isSelected : [])
    }
}

private struct ThreadRow: View {
    let thread: SMSThread
    let line: SMSLine?
    var body: some View {
        let last = thread.last
        HStack(spacing: 12) {
            HaloAvatar(name: thread.contact)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(thread.contact).font(.system(size: 15, weight: thread.unreadCount > 0 ? .semibold : .medium)).foregroundColor(.haloText).lineLimit(1)
                    Spacer()
                    Text(last.date.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundColor(.haloText3)
                }
                HStack(spacing: 6) {
                    Text(last.body).font(.system(size: 13)).foregroundColor(.haloText2).lineLimit(1).privacySensitive()
                    Spacer(minLength: 0)
                    if thread.unreadCount > 0 { Circle().fill(Color.haloAccent).frame(width: 8, height: 8).accessibilityLabel("Unread") }
                }
                if let line { HaloChip(text: line.label, color: .haloText3) }
            }
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

struct ConversationView: View {
    @EnvironmentObject var cloud: CloudModel
    let threadID: String

    var body: some View {
        let thread = cloud.threads.first { $0.id == threadID }
        ScrollView {
            LazyVStack(spacing: 8) {
                if let thread {
                    HStack(spacing: 6) {
                        if let l = cloud.line(thread.lineId) { HaloChip(text: "\(l.label) · \(l.carrier)", icon: "simcard", color: .haloText2) }
                        HaloChip(text: cloud.deviceName(thread.messages[0].deviceId), icon: "candybarphone", color: .haloText3)
                    }
                    ForEach(thread.messages) { m in bubble(m) }
                } else {
                    HaloEmptyState(icon: "tray", title: "Conversation gone")
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).haloScreen()
        .navigationTitle(thread?.contact ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bubble(_ m: SMSMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(m.body).font(.system(size: 15)).foregroundColor(.haloText).textSelection(.enabled).privacySensitive()
            HStack(spacing: 8) {
                Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundColor(.haloText3)
                if let code = OTPCode.extract(from: m.body) {
                    Button { cloud.copyPlain(code, sensitive: true) } label: { HaloChip(text: "\(CloudStrings.copyCode) \(code)", icon: "doc.on.doc", color: .haloAmber).frame(minHeight: 44) }
                        .accessibilityIdentifier("messages.copyCode")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.haloSurface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.haloBorder))
    }
}
