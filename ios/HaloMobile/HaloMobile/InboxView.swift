import SwiftUI

struct InboxView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.inbox.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 36)).foregroundColor(.haloText3)
                        Text("Nothing received yet").font(.system(size: 15, weight: .medium)).foregroundColor(.haloText2)
                        Text("Files sent to this device appear here, and in the Files app under Halo → Received.")
                            .font(.system(size: 12)).foregroundColor(.haloText3).multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.inbox) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.fill").foregroundColor(.haloAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 14, weight: .medium)).foregroundColor(.haloText).lineLimit(1)
                                    Text("\(Bytes.string(item.size)) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 11)).foregroundColor(.haloText3)
                                }
                                Spacer()
                                ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                            }
                            .listRowBackground(Color.haloSurface)
                            .accessibilityIdentifier("inbox.item.\(item.name)")
                        }
                        .onDelete { offsets in offsets.map { model.inbox[$0] }.forEach(model.deleteInboxItem) }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.haloBackground)
            .navigationTitle("Inbox")
            .onAppear { model.refreshInbox() }
        }
    }
}
