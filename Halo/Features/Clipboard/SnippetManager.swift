import Foundation
import AppKit

// MARK: - SnippetExpander (non-isolated, callable from structs)

/// Replaces placeholder tokens in a snippet body with live values.
/// Deliberately NOT @MainActor so TextSnippet.expanded() can call it from any context.
enum SnippetExpander {
    static func expand(_ body: String) -> String {
        var result = body

        // {date} → localized date
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        result = result.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: Date()))

        // {time} → localized time
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        result = result.replacingOccurrences(of: "{time}", with: timeFormatter.string(from: Date()))

        // {clipboard} → current clipboard text
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        result = result.replacingOccurrences(of: "{clipboard}", with: clipboard)

        // {uuid} → fresh UUID
        result = result.replacingOccurrences(of: "{uuid}", with: UUID().uuidString)

        // {random:N} → random alphanumeric string of length N
        if let range = result.range(of: #"\{random:\d+\}"#, options: .regularExpression) {
            let token = String(result[range])
            if let nStr = token.components(separatedBy: ":").last?.dropLast(),
               let n = Int(nStr), n > 0 {
                let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                let random = String((0..<n).map { _ in chars.randomElement()! })
                result = result.replacingOccurrences(of: token, with: random)
            }
        }

        return result
    }
}

// MARK: - TextSnippet

struct TextSnippet: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String                    // "Email Signature"
    var trigger: String                 // "//sig"
    var body: String                    // "Best regards,\n{clipboard}"
    var category: String                // "Email", "Code", "Symbols"
    var usageCount: Int = 0
    var createdAt: Date = Date()

    /// Expand the snippet body by replacing placeholder tokens with live values.
    func expanded() -> String {
        SnippetExpander.expand(body)
    }
}

// MARK: - SnippetManager

/// Central registry of user snippets. Singleton — shared across ClipboardView and Quick Picker.
@MainActor
final class SnippetManager: ObservableObject {

    static let shared = SnippetManager()

    @Published var snippets: [TextSnippet] = []

    private let storageKey = "haloSnippets"
    private let starterLoadedKey = "haloSnippetsStarterLoaded"

    private init() {
        load()
        loadStarterPackIfNeeded()
    }

    // MARK: - CRUD

    func add(_ snippet: TextSnippet) {
        snippets.append(snippet)
        persist()
    }

    func update(_ snippet: TextSnippet) {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx] = snippet
            persist()
        }
    }

    func delete(_ snippet: TextSnippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    func duplicate(_ snippet: TextSnippet) {
        var copy = snippet
        copy.id = UUID()
        copy.name = snippet.name + " Copy"
        copy.usageCount = 0
        copy.createdAt = Date()
        snippets.append(copy)
        persist()
    }

    func recordUsage(_ snippet: TextSnippet) {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx].usageCount += 1
            persist()
        }
    }

    // MARK: - Search

    func search(_ query: String) -> [TextSnippet] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else {
            return snippets.sorted { $0.usageCount > $1.usageCount }
        }
        return snippets.filter {
            $0.name.lowercased().contains(trimmed) ||
            $0.trigger.lowercased().contains(trimmed) ||
            $0.body.lowercased().contains(trimmed) ||
            $0.category.lowercased().contains(trimmed)
        }
        .sorted { $0.usageCount > $1.usageCount }
    }

    /// All unique categories from existing snippets.
    var categories: [String] {
        Array(Set(snippets.map(\.category))).sorted()
    }

    func snippets(in category: String) -> [TextSnippet] {
        snippets.filter { $0.category == category }
    }

    // MARK: - Expansion Engine

    /// Replace placeholder tokens with live values (MainActor wrapper).
    static func expand(_ body: String) -> String {
        SnippetExpander.expand(body)
    }

    // MARK: - Import / Export

    func importFromJSON(data: Data) {
        guard let decoded = try? JSONDecoder().decode([TextSnippet].self, from: data) else { return }
        // Avoid duplicates by trigger
        let existingTriggers = Set(snippets.map(\.trigger))
        let newOnes = decoded.filter { !existingTriggers.contains($0.trigger) }
        snippets.append(contentsOf: newOnes)
        persist()
    }

    func exportToJSON() -> Data? {
        try? JSONEncoder().encode(snippets)
    }

    func importFromCSV(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // Expected format: name,trigger,body,category
        for line in lines.dropFirst() {  // skip header
            let parts = parseCSVLine(line)
            guard parts.count >= 3 else { continue }
            let name = parts[0]
            let trigger = parts[1]
            let body = parts[2]
            let category = parts.count > 3 ? parts[3] : "Imported"

            guard !trigger.isEmpty else { continue }
            // Skip if trigger already exists
            guard !snippets.contains(where: { $0.trigger == trigger }) else { continue }

            snippets.append(TextSnippet(name: name, trigger: trigger, body: body, category: category))
        }
        persist()
    }

    private func parseCSVLine(_ line: String) -> [String] {
        // Simple CSV parser handling quoted fields
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TextSnippet].self, from: data) else { return }
        snippets = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Starter Pack

    private func loadStarterPackIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: starterLoadedKey) else { return }
        UserDefaults.standard.set(true, forKey: starterLoadedKey)

        let starters: [TextSnippet] = [
            // Symbols
            TextSnippet(name: "Right Arrow", trigger: "//arrow", body: "→", category: "Symbols"),
            TextSnippet(name: "Check Mark", trigger: "//check", body: "✓", category: "Symbols"),
            TextSnippet(name: "Cross Mark", trigger: "//cross", body: "✗", category: "Symbols"),
            TextSnippet(name: "Bullet Point", trigger: "//bullet", body: "•", category: "Symbols"),
            TextSnippet(name: "Em Dash", trigger: "//dash", body: "—", category: "Symbols"),
            TextSnippet(name: "Copyright", trigger: "//copy", body: "©", category: "Symbols"),
            TextSnippet(name: "Trademark", trigger: "//tm", body: "™", category: "Symbols"),
            TextSnippet(name: "Shrug", trigger: "//shrug", body: "¯\\_(ツ)_/¯", category: "Symbols"),

            // Date & Time
            TextSnippet(name: "Today's Date", trigger: "//today", body: "{date}", category: "Date & Time"),
            TextSnippet(name: "Current Time", trigger: "//now", body: "{time}", category: "Date & Time"),
            TextSnippet(name: "Date & Time", trigger: "//dt", body: "{date} {time}", category: "Date & Time"),

            // Developer
            TextSnippet(name: "Console Log", trigger: "//log", body: "console.log('{clipboard}');", category: "Dev"),
            TextSnippet(name: "Print Debug", trigger: "//print", body: "print(\"DEBUG: {clipboard}\")", category: "Dev"),
            TextSnippet(name: "TODO Comment", trigger: "//todo", body: "// TODO: {clipboard}", category: "Dev"),
            TextSnippet(name: "FIXME Comment", trigger: "//fixme", body: "// FIXME: {clipboard}", category: "Dev"),
            TextSnippet(name: "UUID", trigger: "//uuid", body: "{uuid}", category: "Dev"),
            TextSnippet(name: "Random Token", trigger: "//token", body: "{random:32}", category: "Dev"),

            // Email
            TextSnippet(name: "Greeting", trigger: "//hi", body: "Hi {clipboard},\n\nHope this message finds you well.\n\n", category: "Email"),
            TextSnippet(name: "Sign-off", trigger: "//regards", body: "Best regards,\n{clipboard}", category: "Email"),
            TextSnippet(name: "Out of Office", trigger: "//ooo", body: "Thanks for your email. I'm currently out of the office and will return on {clipboard}. I'll respond to your message when I'm back.\n\nBest regards", category: "Email"),
        ]

        snippets.append(contentsOf: starters)
        persist()
    }
}
