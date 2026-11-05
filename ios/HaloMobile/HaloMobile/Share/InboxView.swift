import SwiftUI
import QuickLook

/// Compact row for a received file: type icon, name, size · time, share button.
struct InboxRow: View {
    let item: InboxItem
    /// Tapping the row opens it (Quick Look); `nil` for the compact preview on Share, where the row is static.
    var onOpen: (() -> Void)?

    var body: some View {
        HaloListRow(icon: Self.icon(for: item), tint: Self.tint(for: item), title: item.name,
                    subtitle: "\(Bytes.string(item.size)) · \(HaloTime.relative(item.date))") {
            ShareLink(item: item.url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(.body).weight(.semibold)).foregroundColor(.haloAccent)
                    .frame(width: HaloLayout.minTarget, height: HaloLayout.minTarget)
            }
            .accessibilityLabel("\(HaloStrings.Inbox.shareFile) \(item.name)")
            .accessibilityIdentifier("inbox.share.\(item.name)")
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox.item.\(item.name)")
    }

    static func icon(for item: InboxItem) -> String {
        switch item.url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo.fill"
        case "mp4", "mov", "m4v": return "film.fill"
        case "mp3", "m4a", "wav", "aac": return "waveform"
        case "pdf": return "doc.richtext.fill"
        case "zip", "gz", "tar": return "doc.zipper"
        case "swift", "py", "js", "ts", "json", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }
    static func tint(for item: InboxItem) -> Color {
        switch icon(for: item) {
        case "photo.fill": return .haloGreen
        case "film.fill": return .haloAmber
        case "chevron.left.forwardslash.chevron.right": return .haloPurple
        case "doc.richtext.fill": return .haloRed
        default: return .haloAccent
        }
    }
}

/// Full list of received files. Pushed from Share (and Home): tap to open (Quick Look), share button per row, swipe to delete (with confirmation).
struct InboxView: View {
    @EnvironmentObject var model: AppModel
    @State private var preview: URL?
    @State private var pendingDelete: InboxItem?

    var body: some View {
        Group {
            if model.inbox.isEmpty {
                ScrollView {
                    HaloCard {
                        HaloEmptyState(icon: "tray", title: HaloStrings.Inbox.emptyTitle, subtitle: HaloStrings.Inbox.emptyHint)
                    }
                    .padding(HaloLayout.screenPadding)
                }
            } else {
                List {
                    ForEach(model.inbox) { item in
                        InboxRow(item: item) { preview = item.url }
                            .accessibilityAction(named: "Open") { preview = item.url }
                            .background(Color.haloSurface2)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.haloBorder, lineWidth: 1))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: HaloLayout.screenPadding, bottom: 4, trailing: HaloLayout.screenPadding))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                            }
                            .contextMenu {
                                Button { preview = item.url } label: { Label("Open", systemImage: "eye") }
                                Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .haloScreen()
        .navigationTitle(HaloStrings.Inbox.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshInbox() }
        .quickLookPreview($preview)
        // Deletion is permanent on iOS (there is no Trash for an app's own files), so it always asks.
        .confirmationDialog("Delete this file?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { item in
            Button("Delete \(item.name)", role: .destructive) { model.deleteInboxItem(item); pendingDelete = nil }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("It will be removed from this device. This can't be undone.")
        }
    }
}
