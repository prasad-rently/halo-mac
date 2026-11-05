import SwiftUI
import QuickLook

struct InboxView: View {
    @EnvironmentObject var model: AppModel
    @State private var preview: URL?
    @State private var pendingDelete: InboxItem?

    var body: some View {
        NavigationStack {
            Group {
                if model.inbox.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 36)).foregroundColor(.haloText3)
                        Text("Nothing received yet").font(.system(size: 15, weight: .medium)).foregroundColor(.haloText2)
                        Text("Files sent to this device appear here, and in the Files app under On My iPhone → Halo → Received.")
                            .font(.system(size: 12)).foregroundColor(.haloText3).multilineTextAlignment(.center)
                        Text("Receiving works while Halo is open.")
                            .font(.system(size: 12)).foregroundColor(.haloText3)
                    }
                    .padding(32)
                    // A scrollable root so the empty state never collapses (the AI Assistant tab bug, again).
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.inbox) { item in
                            HStack(spacing: 12) {
                                // Tapping the row opens it (Quick Look); the share button hands it to any app.
                                Button { preview = item.url } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.fill").foregroundColor(.haloAccent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name).font(.system(size: 14, weight: .medium)).foregroundColor(.haloText).lineLimit(1)
                                            Text("\(Bytes.string(item.size)) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.system(size: 11)).foregroundColor(.haloText3)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("inbox.open.\(item.name)")
                                ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                                    .accessibilityIdentifier("inbox.share.\(item.name)")
                            }
                            .listRowBackground(Color.haloSurface)
                            .accessibilityIdentifier("inbox.item.\(item.name)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                            }
                            .contextMenu {
                                Button { preview = item.url } label: { Label("Open", systemImage: "eye") }
                                Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.haloBackground)
            .navigationTitle("Inbox")
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
}
