import Foundation

// MARK: - Expenditure models + pattern pack  (F-048)
//
// Data-driven port of the Hamza reference (docs/specs/F-048 §11 + pattern-packs/
// india-bank-sms.v1.json). The pack externalises the parser's word lists + regexes
// (FR-12); the India/UPI defaults ship embedded so the tracker works out of the box
// (a JSON pack can override later). Only transactional SMS (per SmsClassifier) feed
// this pipeline.

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

struct CategoryRule: Codable, Sendable, Hashable {
    let category: String       // display name (see §12)
    let triggers: [String]     // UPPERCASE merchant/keyword substrings
}

struct PatternPack: Codable, Sendable {
    var id: String
    var currency: String
    var balanceLookbehindChars: Int
    var dedupWindowMs: Double
    var amountRegex: String
    var accountRegex: String
    var merchantRegex: String
    var debitWords: [String]
    var creditWords: [String]
    var excludeWords: [String]
    var promoWords: [String]
    var nonBankSenders: [String]
    var balancePrefix: [String]
    var categories: [CategoryRule]

    /// The shipped India/UPI pack — exact Hamza lists (india-bank-sms.v1.json).
    static let indiaDefault = PatternPack(
        id: "india-bank-sms",
        currency: "INR",
        balanceLookbehindChars: 14,
        dedupWindowMs: 120_000,
        amountRegex: #"(?:RS|INR|₹)\.?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#,
        accountRegex: #"(?:X|x|\*){2,}\s*(\d{3,4})|(?:A/C|AC|ACCT|CARD)[^\d]{0,6}(?:X|x|\*)*(\d{3,4})"#,
        merchantRegex: #"(?:\bAT\s+|\bTO\s+|INFO[:\-]\s*)([A-Z0-9][A-Z0-9 &._'-]{2,30}?)(?=\s+(?:ON|VIA|REF|FOR|DATED|\.|,|$))"#,
        debitWords: ["DEBITED", "SPENT", "WITHDRAWN", "PURCHASED", "PURCHASE", "DEDUCTED",
                     "PAID", "SENT", "CHARGED", "TXN OF", "TXN RS", "TXN INR", "DEBIT OF", "PAYMENT OF"],
        creditWords: ["CREDITED", "RECEIVED", "DEPOSITED", "REFUNDED", "ADDED"],
        excludeWords: ["DECLINED", "FAILED", "UNSUCCESSFUL", "REVERSED", "NOT DEBITED", "NOT CREDITED",
                       "IS DUE", "DUE ON", "PAYMENT DUE", "TOTAL DUE", "MIN AMT", "MINIMUM AMOUNT",
                       "WILL BE DEBITED", "WILL BE DEDUCTED", "WILL BE AUTO", "WILL BE CREDITED",
                       "TO BE DEBITED", "TO BE DEDUCTED",
                       "INITIATED", "REQUESTED", "PLEASE PAY", "PAY NOW", "OVERDUE", "PAYABLE", "REMINDER"],
        promoWords: ["OFFER", "DISCOUNT", "SALE", "% OFF", "SHOP NOW", "BUY NOW", "ORDER NOW", "COUPON",
                     "PROMO", "CONGRATULATIONS", "WINNER", "PRIZE", "LUCKY", "APPLY NOW", "PRE-APPROVED",
                     "PREAPPROVED", "LOAN OFFER", "CLAIM", "REWARD POINTS", "VOUCHER", "UNSUBSCRIBE",
                     "T&C", "CLICK HERE", "LIMITED TIME", "HURRY", "EXCITING"],
        nonBankSenders: ["AIRTEL", "JIO", "PAYTM", "PHONEPE", "PHONPE", "MOBIKW", "FREECH", "AMAZON",
                         "FLIPKART", "FKRT", "SWIGGY", "ZOMATO", "EKART", "MYNTRA", "INDANE", "HPGAS",
                         "BHARATGAS", "BHRTGS", "IRCTC", "POLBAZ", "POLICYB", "NETFLIX"],
        balancePrefix: ["BAL", "BALANCE", "AVBL", "AVAILABLE", "AVL", "AVAIL", "LIMIT", "OUTSTANDING", "DUE"],
        categories: [
            .init(category: "Food & Dining", triggers: ["ZOMATO", "SWIGGY", "RESTAURANT", "CAFE", "EATCLUB", "DOMINO", "MCDONALD", "KFC"]),
            .init(category: "Groceries", triggers: ["BIGBASKET", "BLINKIT", "ZEPTO", "DMART", "SUPERMARKET", "GROFERS", "JIOMART"]),
            .init(category: "Shopping", triggers: ["AMAZON", "FLIPKART", "MYNTRA", "AJIO", "MEESHO", "NYKAA", "RETAIL"]),
            .init(category: "Bills & Utilities", triggers: ["ELECTRICITY", "INDANE", "HPGAS", "BHARATGAS", "BROADBAND", "RECHARGE", "DTH", "WATER BILL", "GAS BILL", "AIRTEL", "JIO", "ACT ", "BSNL"]),
            .init(category: "Transport", triggers: ["UBER", "OLA", "RAPIDO", "IRCTC", "FUEL", "INDIAN OIL", "IOCL", "BPCL", "HPCL", "METRO", "FASTAG", "PETROL"]),
            .init(category: "Entertainment", triggers: ["NETFLIX", "SPOTIFY", "PRIME", "HOTSTAR", "BOOKMYSHOW", "JIOCINEMA", "SONYLIV"]),
            .init(category: "Health", triggers: ["PHARMEASY", "APOLLO", "HOSPITAL", "PHARMACY", "1MG", "NETMEDS", "MEDPLUS"]),
            .init(category: "Financial", triggers: ["EMI", "LIC", "INSURANCE", "MUTUAL FUND", "SIP", "CRED", "ZERODHA", "GROWW"]),
            .init(category: "Transfers", triggers: ["UPI", "IMPS", "NEFT", "RTGS"])
        ])

    // MARK: Category resolution

    /// First rule whose any trigger appears in merchant+body → its category;
    /// credit → Income; otherwise Other. (Transfers are set separately by D7.)
    func category(merchant: String?, body: String, direction: TransactionDirection) -> String {
        if direction == .credit { return "Income" }
        let hay = ((merchant ?? "") + " " + body).uppercased()
        for rule in categories where rule.triggers.contains(where: { hay.contains($0) }) {
            return rule.category
        }
        return "Other"
    }

    /// All category names for the UI legend (+ synthetic Income/Transfers/Other).
    var allCategoryNames: [String] {
        categories.map(\.category) + ["Income", "Transfers", "Other"]
    }
}
