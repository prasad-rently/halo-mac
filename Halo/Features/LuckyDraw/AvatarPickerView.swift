import SwiftUI
import UniformTypeIdentifiers

// MARK: - AvatarPickerView (F-053)
//
// The popover behind an entry's avatar button: pick an emoji, import a photo, or go back to the
// derived monogram. Animated emoji and characters are not offered — no art ships yet — so there are
// no empty tabs to apologise for.

struct AvatarPickerView: View {
    @ObservedObject var store: LuckyDrawStore
    let entry: DrawEntry
    let rosterID: UUID?
    var dismiss: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case emoji = "Emoji", photo = "Photo"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .emoji
    @State private var emojiText = ""
    @State private var message: String?
    @State private var busy = false
    @State private var dropTargeted = false

    /// The entry as it is now (the popover's copy can be stale after a change).
    private var current: DrawEntry { store.selected?.entries.first { $0.id == entry.id } ?? entry }

    private let columns = Array(repeating: GridItem(.flexible(minimum: 24), spacing: 4), count: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AvatarView(avatar: current.avatar, label: current.label, rosterID: rosterID, diameter: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.label).font(.system(size: 13, weight: .semibold)).foregroundColor(.haloText).lineLimit(1)
                    Text("Avatar").font(.system(size: 10.5)).foregroundColor(.haloText3)
                }
                Spacer()
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch tab {
            case .emoji: emojiTab
            case .photo: photoTab
            }

            if let message {
                Text(message).font(.system(size: 11)).foregroundColor(.haloAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if current.avatar != nil {
                Button("Remove avatar") { store.setAvatar(nil, for: current); dismiss() }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundColor(.haloRed)
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(Color.haloSurface)
    }

    // MARK: Emoji

    private var emojiTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Type or paste an emoji, then ⏎", text: $emojiText)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.haloText)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.haloSurface2)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.haloBorder2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .onSubmit { applyTyped() }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(AvatarEmojiCatalog.common, id: \.self) { e in
                    Button { choose(e) } label: { Text(e).font(.system(size: 20)).frame(width: 26, height: 26) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func applyTyped() {
        let t = emojiText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if EmojiValidation.isSingleEmoji(t) { choose(t) }
        else { message = "That isn't a single emoji. Paste exactly one." }
    }

    private func choose(_ emoji: String) {
        store.setAvatar(.emoji(emoji), for: current)
        dismiss()
    }

    // MARK: Photo

    private var photoTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { chooseFile() } label: {
                Label(busy ? "Importing…" : "Choose a photo…", systemImage: "photo")
                    .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(ResultButtonStyle(prominent: true)).disabled(busy)

            Text("…or drop one here")
                .font(.system(size: 11)).foregroundColor(.haloText3)
                .frame(maxWidth: .infinity, minHeight: 54)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(dropTargeted ? Color.haloAccent : Color.haloBorder2,
                            style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)

            Text("Stored only on this Mac, as a small copy — never uploaded — and deleted with the entry or roster.")
                .font(.system(size: 10.5)).foregroundColor(.haloText3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for \(current.label)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPhoto(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) } else { url = item as? URL }
            guard let url else { return }
            DispatchQueue.main.async { importPhoto(url) }
        }
        return true
    }

    private func importPhoto(_ url: URL) {
        busy = true; message = nil
        Task {
            do {
                try await store.setPhoto(from: url, for: current)
                busy = false
                dismiss()
            } catch {
                busy = false
                message = (error as? LocalizedError)?.errorDescription ?? "Couldn't use that picture."
            }
        }
    }
}
