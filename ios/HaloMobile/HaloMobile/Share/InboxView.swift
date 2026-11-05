import SwiftUI

/// Compact row for a received file: type icon, name, size · time, share button.
struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        HaloListRow(icon: Self.icon(for: item), tint: Self.tint(for: item), title: item.name,
                    subtitle: "\(Bytes.string(item.size)) · \(HaloTime.relative(item.date))") {
            ShareLink(item: item.url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(.body).weight(.semibold)).foregroundColor(.haloAccent)
                    .frame(width: HaloLayout.minTarget, height: HaloLayout.minTarget)
            }
            .accessibilityLabel("\(HaloStrings.Inbox.shareFile) \(item.name)")
        }
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

/// Full list of received files. Pushed from Share (and Home); swipe to delete, share button per row.
struct InboxView: View {
    @EnvironmentObject var model: AppModel

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
                        InboxRow(item: item)
                            .background(Color.haloSurface2)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.haloBorder, lineWidth: 1))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: HaloLayout.screenPadding, bottom: 4, trailing: HaloLayout.screenPadding))
                    }
                    .onDelete { offsets in offsets.map { model.inbox[$0] }.forEach(model.deleteInboxItem) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .haloScreen()
        .navigationTitle(HaloStrings.Inbox.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshInbox() }
    }
}
