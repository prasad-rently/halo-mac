import Foundation

// MARK: - TransactionParser  (F-048 §11.3)
//
// Deterministic, offline SMS → transaction parser (Hamza heuristics). Pure/stateless
// (enum) — no actor isolation needed. Works on the uppercased body in UTF-16
// (NSString) offsets so verb/amount distances are comparable.
//
//   reject → direction(earliest verb) → amount(regex, drop-balance, nearest-to-verb)
//          → account tail + merchant → Ok/Unreadable/NotTransaction

enum TransactionParser {

    /// Parse one already-classified-transactional message. Category is left as a
    /// placeholder ("") — the pipeline assigns it via `PatternPack.category(...)`.
    static func parse(sender rawSender: String, body rawBody: String,
                      messageId: String, date: Date, pack: PatternPack) -> ParseOutcome {
        let sender = rawSender.uppercased()
        let upper = rawBody.uppercased() as NSString

        // 1–3. Hard rejects → NotTransaction.
        if sender.hasSuffix("-P") { return .notTransaction }
        if pack.nonBankSenders.contains(where: { sender.contains($0) }) { return .notTransaction }
        if pack.excludeWords.contains(where: { upper.contains($0) }) { return .notTransaction }
        if pack.promoWords.contains(where: { upper.contains($0) }) { return .notTransaction }
        // Credit-card bill-payment acknowledgements (pack v2): the card's purchases are already counted one by one.
        let whole = NSRange(location: 0, length: upper.length)
        if pack.rejectPatterns.contains(where: { $0.firstMatch(in: upper as String, range: whole) != nil }) { return .notTransaction }

        // 4. Direction — earliest debit vs credit verb wins.
        guard let (direction, verbLoc) = earliestVerb(in: upper, pack: pack) else {
            return .notTransaction
        }

        // 5. Amount — regex, drop balances, nearest-to-verb.
        guard let amount = nearestAmount(in: upper, verbLoc: verbLoc, pack: pack) else {
            return .unreadable
        }

        // 6. Extras (best-effort).
        let account = firstCapture(pack.account, in: upper)
        let merchant = firstCapture(pack.merchant, in: upper)?.trimmingCharacters(in: .whitespaces)

        var confidence = 0.6
        if account != nil { confidence += 0.2 }
        if merchant != nil { confidence += 0.2 }
        confidence = min(confidence, 1.0)

        let txn = ParsedTransaction(
            id: messageId, amount: amount, currency: pack.currency, direction: direction,
            merchant: merchant, category: "", date: date, accountHint: account,
            confidence: confidence, sourceMessageId: messageId, sender: rawSender, body: rawBody)
        return .ok(txn)
    }

    // MARK: Direction

    private static func earliestVerb(in upper: NSString, pack: PatternPack) -> (TransactionDirection, Int)? {
        var best: (dir: TransactionDirection, loc: Int)?
        func consider(_ words: [String], _ dir: TransactionDirection) {
            for w in words {
                let r = upper.range(of: w)
                if r.location != NSNotFound, best == nil || r.location < best!.loc {
                    best = (dir, r.location)
                }
            }
        }
        consider(pack.debitWords, .debit)
        consider(pack.creditWords, .credit)
        return best.map { ($0.dir, $0.loc) }
    }

    // MARK: Amount

    private static func nearestAmount(in upper: NSString, verbLoc: Int, pack: PatternPack) -> Double? {
        let full = NSRange(location: 0, length: upper.length)
        var candidates: [(value: Double, loc: Int)] = []
        var prevEnd = 0

        pack.amount.enumerateMatches(in: upper as String, range: full) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            let loc = m.range.location, end = loc + m.range.length
            let isBalance = isBalanceAmount(upper, loc: loc, end: end, prevEnd: prevEnd, pack: pack)
            prevEnd = end
            if isBalance { return }
            let numStr = upper.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            if let v = Double(numStr) { candidates.append((v, loc)) }
        }
        guard !candidates.isEmpty else { return nil }
        // Nearest to the direction verb (first wins a tie, like the phone).
        return candidates.min { abs($0.loc - verbLoc) < abs($1.loc - verbLoc) }?.value
    }

    /// An amount is the BALANCE, not the transaction, when (a) a balance word (a whole word) sits in the
    /// `balanceContextChars` before it — looking back only to the previous sentence boundary and the previous amount, so
    /// "Low avl bal alert. Rs 700 debited" keeps the 700 — or (b) the text right after it reads "is your available
    /// balance". (The old rule looked back a fixed 14 chars, which missed "AVAILABLE BALANCE IN YOUR ACCOUNT IS INR 5,000".)
    private static func isBalanceAmount(_ upper: NSString, loc: Int, end: Int, prevEnd: Int, pack: PatternPack) -> Bool {
        var from = max(prevEnd, loc - pack.balanceContextChars, 0)
        if from < loc {
            let seg = upper.substring(with: NSRange(location: from, length: loc - from))
            let segRange = NSRange(location: 0, length: (seg as NSString).length)
            var cut = -1
            pack.balanceClauseBoundary.enumerateMatches(in: seg, range: segRange) { m, _, _ in
                if let m { cut = m.range.location + m.range.length }
            }
            if cut >= 0 { from += cut }
        }
        if from < loc {
            for w in pack.balancePrefix {
                let n = w.utf16.count
                var scan = from
                while scan < loc {
                    let r = upper.range(of: w, options: [], range: NSRange(location: scan, length: loc - scan))
                    if r.location == NSNotFound || r.location + n > loc { break }
                    // A WHOLE word: 'Dear BALAJI' / 'PVT LIMITED' / 'DUES' are not balance words.
                    let before = r.location == 0 || !PatternPack.isLetter(upper.character(at: r.location - 1))
                    let after = r.location + n >= upper.length || !PatternPack.isLetter(upper.character(at: r.location + n))
                    if before && after { return true }
                    scan = r.location + 1
                }
            }
        }
        let tailLen = min(balanceAfterChars, upper.length - end)
        guard tailLen > 0 else { return false }
        let tail = upper.substring(with: NSRange(location: end, length: tailLen))
        return pack.balanceAfter.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) != nil
    }

    private static let balanceAfterChars = 64

    // MARK: Regex capture helper

    private static func firstCapture(_ re: NSRegularExpression, in upper: NSString) -> String? {
        let full = NSRange(location: 0, length: upper.length)
        guard let m = re.firstMatch(in: upper as String, range: full) else { return nil }
        // Return the first non-empty capture group.
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location != NSNotFound, r.length > 0 { return upper.substring(with: r) }
        }
        return nil
    }
}
