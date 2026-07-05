import SwiftUI
import Combine

// MARK: - ExpenditureViewModel  (F-048)
//
// Reads the F-044 synced+decrypted SMS (via its own SMSSyncClient), runs the
// deterministic pipeline, and exposes month aggregates + category breakdown + the
// transaction list for ExpenditureView. Re-runs whenever the cloud data or the
// user's overrides change (the re-parse = delete-sync mirror, D10).

@MainActor
final class ExpenditureViewModel: ObservableObject {
    let client = SMSSyncClient()
    private let store = ExpenditureStore.shared
    private let pack = PatternPack.indiaDefault

    @Published private(set) var result = TransactionPipeline.Result(transactions: [], unreadableCount: 0)
    @Published var selectedMonth: Date = Calendar.current.startOfMonth(for: Date())
    @Published var selectedCategory: String?     // nil = all

    private var bag = Set<AnyCancellable>()

    init() {
        // Re-parse when cloud data or overrides change.
        client.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.reparse() } }
            .store(in: &bag)
        store.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.reparse() } }
            .store(in: &bag)
    }

    // MARK: Cloud connection (reuses F-044 config)

    var state: SMSSyncClient.State { client.state }
    var isConfigured: Bool { client.isConfigured }

    func autoConnect() {
        guard isConfigured, case .unconfigured = client.state,
              let pass = CloudConfigStore.shared.cachedPassphrase else { return }
        Task { await client.connect(passphrase: pass) }
    }

    func connect(passphrase: String) {
        Task {
            await client.connect(passphrase: passphrase)
            if case .connected = client.state { CloudConfigStore.shared.cachedPassphrase = passphrase }
        }
    }

    // MARK: Parse

    private func reparse() {
        let messages = client.threads.flatMap(\.messages)
        result = TransactionPipeline.run(messages: messages, pack: pack, overrides: store.overrides)
    }

    // MARK: Overrides (D9)

    func recategorize(_ txn: ParsedTransaction, to category: String) { store.setCategory(txn.id, category) }
    func exclude(_ txn: ParsedTransaction) { store.exclude(txn.id) }
    func forceInclude(id: String) { store.forceInclude(id) }
    var categoryNames: [String] { pack.allCategoryNames }

    // MARK: Month navigation

    func stepMonth(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: delta, to: selectedMonth) {
            selectedMonth = Calendar.current.startOfMonth(for: d)
        }
    }
    var monthLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: selectedMonth)
    }
    var isCurrentMonth: Bool {
        Calendar.current.isDate(selectedMonth, equalTo: Date(), toGranularity: .month)
    }

    // MARK: Aggregates (transfers + dupes excluded from totals)

    /// All transactions in the selected month (incl. transfers/dupes, for the list).
    var monthTransactions: [ParsedTransaction] {
        result.transactions.filter {
            Calendar.current.isDate($0.date, equalTo: selectedMonth, toGranularity: .month)
        }
    }

    private var countableThisMonth: [ParsedTransaction] {
        monthTransactions.filter(\.countsTowardTotals)
    }

    var spent: Double { countableThisMonth.filter { $0.direction == .debit }.reduce(0) { $0 + $1.amount } }
    var received: Double { countableThisMonth.filter { $0.direction == .credit }.reduce(0) { $0 + $1.amount } }
    var net: Double { received - spent }
    var unreadableCount: Int { result.unreadableCount }

    /// Spend-by-category for the month (debit only), descending.
    var categoryBreakdown: [(category: String, amount: Double)] {
        var totals: [String: Double] = [:]
        for t in countableThisMonth where t.direction == .debit {
            totals[t.category, default: 0] += t.amount
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.amount > $1.amount }
    }

    /// The list to display, honoring the category filter.
    var displayedTransactions: [ParsedTransaction] {
        guard let cat = selectedCategory else { return monthTransactions }
        return monthTransactions.filter { $0.category == cat }
    }

    // MARK: CSV export (FR-13)

    func exportCSV() -> String {
        let f = ISO8601DateFormatter()
        var rows = ["id,date,direction,amount,currency,merchant,category,account,sender,transfer,duplicate"]
        for t in result.transactions {
            let fields = [t.id, f.string(from: t.date), t.direction.rawValue,
                          String(format: "%.2f", t.amount), t.currency,
                          t.merchant ?? "", t.category, t.accountHint ?? "", t.sender,
                          t.isTransfer ? "1" : "0", t.isDuplicate ? "1" : "0"]
            rows.append(fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    /// `₹1,23,456.78` grouping (en-IN).
    static func formatINR(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "INR"
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = amount.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return f.string(from: NSNumber(value: amount)) ?? "₹\(amount)"
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}
