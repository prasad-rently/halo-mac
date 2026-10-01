import Foundation

// MARK: - TransactionPipeline  (F-048 §11.1 / §11.4)
//
// classify(keep transactional) → parse → markSelfTransfers → dedup(±120s, cross-device)
// → categorize → apply overrides. Pure/stateless; re-run on every load, which is the
// delete-sync mirror (D10) — deleted SMS simply don't reappear in the input.

enum TransactionPipeline {

    struct Result: Equatable {
        var transactions: [ParsedTransaction]   // includes transfers + dupes (flagged)
        var unreadableCount: Int                // had a verb, no amount (D5)
    }

    static func run(messages: [SMSMessage], pack: PatternPack,
                    overrides: ExpenditureOverrides) -> Result {
        var oks: [ParsedTransaction] = []
        var unreadable = 0

        for m in messages {
            if overrides.excludedIds.contains(m.id) { continue }          // force-exclude (D9)
            let forced = overrides.includedIds.contains(m.id)             // force-include (D9)
            guard m.category == .transactional || forced else { continue } // keep transactional only

            switch TransactionParser.parse(sender: m.contactNumber, body: m.body,
                                           messageId: m.id, date: m.date, pack: pack) {
            case .ok(var t):
                t.forceIncluded = forced
                t.category = overrides.categoryById[m.id]
                    ?? pack.category(merchant: t.merchant, body: t.body, direction: t.direction)
                oks.append(t)
            case .unreadable:
                if !forced { unreadable += 1 }   // only genuine unreadables count (D5)
            case .notTransaction:
                break
            }
        }

        markSelfTransfers(&oks)
        dedup(&oks, windowMs: pack.dedupWindowMs)
        for i in oks.indices where oks[i].isTransfer { oks[i].category = "Transfers" }
        oks.sort { $0.date > $1.date }
        return Result(transactions: oks, unreadableCount: unreadable)
    }

    // MARK: Self-transfers (D7) — same day + same amount debit+credit → cancel

    static func markSelfTransfers(_ txns: inout [ParsedTransaction]) {
        let cal = Calendar.current
        var buckets: [String: (debits: [Int], credits: [Int])] = [:]
        for (i, t) in txns.enumerated() {
            let c = cal.dateComponents([.year, .month, .day], from: t.date)
            let key = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)|\(Int((t.amount * 100).rounded()))"
            if t.direction == .debit { buckets[key, default: ([], [])].debits.append(i) }
            else { buckets[key, default: ([], [])].credits.append(i) }
        }
        for (_, b) in buckets {
            for k in 0..<min(b.debits.count, b.credits.count) {
                txns[b.debits[k]].isTransfer = true
                txns[b.credits[k]].isTransfer = true
            }
        }
    }

    // MARK: Near-duplicate dedup (D8/D15) — same amount+direction within window,
    // regardless of device (the input is a flat cross-device message list).

    static func dedup(_ txns: inout [ParsedTransaction], windowMs: Double) {
        let window = windowMs / 1000
        var kept: [Int] = []
        for i in txns.indices.sorted(by: { txns[$0].date < txns[$1].date }) {
            if txns[i].isTransfer { continue }
            let t = txns[i]
            let isDup = kept.contains { j in
                let k = txns[j]
                return k.amount == t.amount && k.direction == t.direction
                    && abs(k.date.timeIntervalSince(t.date)) <= window
            }
            if isDup { txns[i].isDuplicate = true } else { kept.append(i) }
        }
    }
}
