import Foundation

// MARK: - ConversationStore  (F-046 D11 — local conversation persistence)
//
// Saved chat sessions persisted to Application Support as JSON (a privacy surface
// the user can clear/delete). Only the text turns are stored — enough to restore
// a readable conversation and re-seed context; ephemeral tool-activity rows are
// not persisted. No content ever leaves the device here.

struct SavedTurn: Codable, Equatable, Sendable {
    let role: String        // "user" | "assistant"
    let text: String
}

struct SavedConversation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var turns: [SavedTurn]

    init(id: UUID = UUID(), title: String, createdAt: Date = Date(),
         updatedAt: Date = Date(), turns: [SavedTurn]) {
        self.id = id; self.title = title
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.turns = turns
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var conversations: [SavedConversation] = []
    private let fileURL: URL

    init(fileURL: URL = ConversationStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai-conversations.json")
    }

    /// Insert or replace, keeping the list most-recent-first.
    func upsert(_ c: SavedConversation) {
        if let idx = conversations.firstIndex(where: { $0.id == c.id }) {
            conversations[idx] = c
        } else {
            conversations.append(c)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    func delete(id: UUID) {
        conversations.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        conversations.removeAll()
        save()
    }

    /// A concise title from the first user message.
    static func title(from firstUserText: String) -> String {
        let trimmed = firstUserText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.isEmpty { return "New conversation" }
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SavedConversation].self, from: data) else { return }
        conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(conversations) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
