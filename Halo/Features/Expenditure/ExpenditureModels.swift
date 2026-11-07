import Foundation

// MARK: - Expenditure models + pattern pack  (F-048)
//
// Data-driven port of the Hamza reference (docs/specs/F-048 §11 + pattern-packs/
// india-bank-sms.v1.json). The pack externalises the parser's word lists + regexes
// (FR-12). The pack is the bundled JSON (see `PatternPack` below) — the same file the
// Android app reads — so there is no second copy in code. Only transactional SMS
// (per SmsClassifier) feed this pipeline.

enum TransactionDirection: String, Codable, Sendable {
    case debit, credit
    var isExpense: Bool { self == .debit }
}

/// Three-way parse result (D5). Only `.unreadable` (had a verb, no amount) counts
/// toward the "couldn't read" tally.
enum ParseOutcome: Equatable {
    case ok(ParsedTransaction)
    case unreadable
    case notTransaction
}

struct ParsedTransaction: Identifiable, Hashable, Sendable {
    let id: String                // == sourceMessageId
    var amount: Double
    var currency: String
    var direction: TransactionDirection
    var merchant: String?
    var category: String
    var date: Date
    var accountHint: String?
    var confidence: Double
    let sourceMessageId: String
    let sender: String
    let body: String
    var isTransfer: Bool = false  // self-transfer (D7) — excluded from totals
    var isDuplicate: Bool = false // near-dup collapsed (D8/D15)
    var forceIncluded: Bool = false

    /// Counts toward spend/income totals: not a transfer, not a collapsed duplicate.
    var countsTowardTotals: Bool { !isTransfer && !isDuplicate }
}

// MARK: - Pattern pack

struct CategoryRule: Sendable, Hashable {
    let category: String        // display name (see §12)
    let triggers: [String]      // UPPERCASE merchant/keyword substrings
    /// Whole-word triggers (pack v2): must not sit inside a longer run of A-Z letters, so CRED does not match CREDITED.
    var wordTriggers: [String] = []
}

/// The pack's `classifier` section (F-044 §7.4). Read by `SmsClassifier`; the phone reads the same section.
struct ClassifierRules: Sendable {
    var otpKeywords: [String]
    var otpNumber: NSRegularExpression
    var govSenders: [String]
    var govKeywords: [String]
    var transactionalStrong: [String]
    var moneyTokens: [String]
    var transactionalVerbs: [String]
    var serviceKeywords: [String]
    var promoKeywords: [String]
    var personalDigitsMin: Int
    var personalDigitsMax: Int
}

/// The parser/classifier rules, loaded from `docs/specs/pattern-packs/india-bank-sms.v1.json` — the SAME file the
/// Android build packages into its resources, so the two platforms cannot drift. There is no second copy in code.
///
/// The JSON is a bundle resource of the Halo app target (file reference with an `SOURCE_ROOT`-relative path into
/// `docs/`, listed in the Copy Bundle Resources phase), so a sandboxed release build finds it with `Bundle.main`
/// exactly as it finds `signatures.json`; the unit tests run inside the Halo host app, where `Bundle.main` is Halo.app.
struct PatternPack: @unchecked Sendable {   // NSRegularExpression is immutable and thread-safe
    var id: String
    var version: Int
    var currency: String
    var balanceContextChars: Int
    var dedupWindowMs: Double
    var amountRegex: String
    var accountRegex: String
    var merchantRegex: String
    var debitWords: [String]
    var creditWords: [String]
    var excludeWords: [String]
    /// Regexes over the UPPERCASED body; a hit means NotTransaction (credit-card bill-payment acknowledgements).
    var rejectPatterns: [NSRegularExpression]
    var promoWords: [String]
    var nonBankSenders: [String]
    var balancePrefix: [String]
    var balanceClauseBoundary: NSRegularExpression
    var balanceAfter: NSRegularExpression
    var categories: [CategoryRule]
    var classifier: ClassifierRules

    // Compiled once (the parser used to rebuild these NSRegularExpressions for every message).
    let amount: NSRegularExpression
    let account: NSRegularExpression
    let merchant: NSRegularExpression

    static let resourceName = "india-bank-sms.v1"

    enum PackError: Error { case missing(String), malformed(String) }

    /// The shipped India/UPI pack, read from the bundled JSON. If the resource is missing (a packaging mistake —
    /// `PatternPackTests` fails on it) the app degrades to an inert pack that recognises nothing, rather than crashing.
    static let indiaDefault: PatternPack = {
        for bundle in [Bundle.main, Bundle(for: BundleToken.self)] {
            if let url = bundle.url(forResource: resourceName, withExtension: "json"),
               let data = try? Data(contentsOf: url), let pack = try? parse(data) { return pack }
        }
        assertionFailure("\(resourceName).json is not in the app bundle")
        return inert
    }()
    private final class BundleToken {}

    // MARK: Parsing

    static func parse(_ data: Data) throws -> PatternPack {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PackError.malformed("root") }
        func obj(_ o: [String: Any], _ k: String) throws -> [String: Any] {
            guard let v = o[k] as? [String: Any] else { throw PackError.missing(k) }; return v
        }
        func list(_ o: [String: Any], _ k: String) throws -> [String] {
            guard let v = o[k] as? [String] else { throw PackError.missing(k) }; return v
        }
        func str(_ o: [String: Any], _ k: String) throws -> String {
            guard let v = o[k] as? String else { throw PackError.missing(k) }; return v
        }
        func int(_ o: [String: Any], _ k: String) throws -> Int {
            guard let v = o[k] as? Int else { throw PackError.missing(k) }; return v
        }
        func re(_ p: String, _ opts: NSRegularExpression.Options = []) throws -> NSRegularExpression {
            do { return try NSRegularExpression(pattern: p, options: opts) } catch { throw PackError.malformed(p) }
        }
        let tuning = try obj(root, "tuning"), c = try obj(root, "classifier"), p = try obj(root, "parser")
        guard let rules = try obj(root, "categories")["rules"] as? [[String: Any]] else { throw PackError.missing("categories.rules") }
        let cats = try rules.map {
            CategoryRule(category: try str($0, "category"), triggers: try list($0, "triggers"),
                         wordTriggers: ($0["wordTriggers"] as? [String]) ?? [])
        }
        // The pack's regexes are written case-tolerant ("at"/"to"/"x"); they run over the UPPERCASED body, as on the phone.
        let amountRegex = try str(p, "amountRegex"), accountRegex = try str(p, "accountRegex"), merchantRegex = try str(p, "merchantRegex")
        return PatternPack(
            id: try str(root, "id"), version: try int(root, "version"), currency: try str(root, "currency"),
            balanceContextChars: try int(tuning, "balanceContextChars"),
            dedupWindowMs: Double(try int(tuning, "dedupWindowMs")),
            amountRegex: amountRegex, accountRegex: accountRegex, merchantRegex: merchantRegex,
            debitWords: try list(p, "debitWords"), creditWords: try list(p, "creditWords"),
            excludeWords: try list(p, "excludeWords"),
            rejectPatterns: try list(p, "rejectPatterns").map { try re($0) },
            promoWords: try list(p, "promoWords"), nonBankSenders: try list(p, "nonBankSenders"),
            balancePrefix: try list(p, "balancePrefix"),
            balanceClauseBoundary: try re(try str(p, "balanceClauseBoundaryRegex")),
            balanceAfter: try re(try str(p, "balanceAfterRegex")),
            categories: cats,
            classifier: ClassifierRules(
                otpKeywords: try list(c, "otpKeywords"), otpNumber: try re(try str(c, "otpNumberRegex"), .caseInsensitive),
                govSenders: try list(c, "govSenders"), govKeywords: try list(c, "govKeywords"),
                transactionalStrong: try list(c, "transactionalStrong"), moneyTokens: try list(c, "moneyTokens"),
                transactionalVerbs: try list(c, "transactionalVerbs"), serviceKeywords: try list(c, "serviceKeywords"),
                promoKeywords: try list(c, "promoKeywords"),
                personalDigitsMin: try int(tuning, "personalSenderDigitsMin"), personalDigitsMax: try int(tuning, "personalSenderDigitsMax")),
            amount: try re(amountRegex, .caseInsensitive), account: try re(accountRegex, .caseInsensitive),
            merchant: try re(merchantRegex, .caseInsensitive))
    }

    /// Recognises nothing: no verbs, no keywords. Only the fallback for a missing resource.
    private static let inert: PatternPack = {
        let never = try! NSRegularExpression(pattern: "(?!)")
        return PatternPack(
            id: "inert", version: 0, currency: "INR", balanceContextChars: 0, dedupWindowMs: 120_000,
            amountRegex: "(?!)", accountRegex: "(?!)", merchantRegex: "(?!)", debitWords: [], creditWords: [],
            excludeWords: [], rejectPatterns: [], promoWords: [], nonBankSenders: [], balancePrefix: [],
            balanceClauseBoundary: never, balanceAfter: never, categories: [],
            classifier: ClassifierRules(otpKeywords: [], otpNumber: never, govSenders: [], govKeywords: [],
                transactionalStrong: [], moneyTokens: [], transactionalVerbs: [], serviceKeywords: [], promoKeywords: [],
                personalDigitsMin: 7, personalDigitsMax: 15),
            amount: never, account: never, merchant: never)
    }()

    // MARK: Matching helpers (shared by the parser and the categoriser)

    /// A–Z only: the boundary test for word triggers and balance words (the text is already uppercased).
    static func isLetter(_ u: unichar) -> Bool { u >= 65 && u <= 90 }

    /// True when `word` occurs in `hay` with no A–Z letter immediately before or after it.
    static func containsWord(_ hay: NSString, _ word: String) -> Bool {
        let n = word.utf16.count
        var from = 0
        while from < hay.length {
            let r = hay.range(of: word, options: [], range: NSRange(location: from, length: hay.length - from))
            if r.location == NSNotFound { return false }
            let before = r.location == 0 || !isLetter(hay.character(at: r.location - 1))
            let after = r.location + n >= hay.length || !isLetter(hay.character(at: r.location + n))
            if before && after { return true }
            from = r.location + 1
        }
        return false
    }

    // MARK: Category resolution

    /// First rule whose any trigger appears in merchant+body (or whose wordTrigger appears as a whole word) → its
    /// category; credit → Income; otherwise Other. (Transfers are set separately by D7.)
    func category(merchant: String?, body: String, direction: TransactionDirection) -> String {
        if direction == .credit { return "Income" }
        let hay = ((merchant ?? "") + " " + body).uppercased()
        let ns = hay as NSString
        for rule in categories
        where rule.triggers.contains(where: { hay.contains($0) }) || rule.wordTriggers.contains(where: { Self.containsWord(ns, $0) }) {
            return rule.category
        }
        return "Other"
    }

    /// All category names for the UI legend (+ synthetic Income/Transfers/Other).
    var allCategoryNames: [String] {
        categories.map(\.category) + ["Income", "Transfers", "Other"]
    }
}
