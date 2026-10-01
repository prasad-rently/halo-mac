import Foundation

// MARK: - Expenditure overrides + store  (F-048 D9)
//
// User corrections that outrank automatic rules: force-include / force-exclude a
// message, and re-categorize a transaction. Precedence id > sender > auto. Persisted
// to UserDefaults as JSON. (SQLite TxnStore mirror, D10, is deferred — re-parsing the
// live F-044 data on each load already gives the delete-sync semantics.)

struct ExpenditureOverrides: Codable, Equatable {
    var excludedIds: Set<String> = []
    var includedIds: Set<String> = []
    var categoryById: [String: String] = [:]
}

@MainActor
final class ExpenditureStore: ObservableObject {
    static let shared = ExpenditureStore()

    @Published private(set) var overrides = ExpenditureOverrides()
    private let key = "haloExpenditureOverrides"

    init() { load() }

    func setCategory(_ id: String, _ category: String) {
        overrides.categoryById[id] = category; save()
    }
    func clearCategory(_ id: String) {
        overrides.categoryById[id] = nil; save()
    }
    func exclude(_ id: String) {
        overrides.excludedIds.insert(id); overrides.includedIds.remove(id); save()
    }
    func forceInclude(_ id: String) {
        overrides.includedIds.insert(id); overrides.excludedIds.remove(id); save()
    }
    func clearInclusion(_ id: String) {
        overrides.excludedIds.remove(id); overrides.includedIds.remove(id); save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ExpenditureOverrides.self, from: data) else { return }
        overrides = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
