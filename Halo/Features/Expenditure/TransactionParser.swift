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

        // 4. Direction — earliest debit vs credit verb wins.
        guard let (direction, verbLoc) = earliestVerb(in: upper, pack: pack) else {
            return .notTransaction
        }

        // 5. Amount — regex, drop balances, nearest-to-verb.
        guard let amount = nearestAmount(in: upper, verbLoc: verbLoc, pack: pack) else {
            return .unreadable
        }

        // 6. Extras (best-effort).
        let account = firstCapture(pack.accountRegex, in: upper)
        let merchant = firstCapture(pack.merchantRegex, in: upper)?.trimmingCharacters(in: .whitespaces)

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
        guard let re = try? NSRegularExpression(pattern: pack.amountRegex) else { return nil }
        let full = NSRange(location: 0, length: upper.length)
        var candidates: [(value: Double, loc: Int)] = []

        re.enumerateMatches(in: upper as String, range: full) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            let matchLoc = m.range.location
            // Drop balance amounts: look back up to N chars for a balance prefix.
            let backLen = min(pack.balanceLookbehindChars, matchLoc)
            let back = upper.substring(with: NSRange(location: matchLoc - backLen, length: backLen))
            if pack.balancePrefix.contains(where: { back.contains($0) }) { return }

            let numStr = upper.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            if let v = Double(numStr) { candidates.append((v, matchLoc)) }
        }
        guard !candidates.isEmpty else { return nil }
        // Nearest to the direction verb.
        return candidates.min { abs($0.loc - verbLoc) < abs($1.loc - verbLoc) }?.value
    }

    // MARK: Regex capture helper

    private static func firstCapture(_ pattern: String, in upper: NSString) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
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
