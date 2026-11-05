import SwiftUI

// MARK: - SMS Console models  (F-044)
//
// Value types for the desktop SMS console. Grouping hierarchy (F-044 §7.5):
//   Device → SIM line (own number + carrier) → per-line contact thread → message.

/// The 8-category classifier taxonomy (from the Hamza reference; F-044 §7.4).
enum SMSCategory: String, CaseIterable, Identifiable, Sendable {
    case transactional, otp, personal, government, service, promotional, uncategorized
    var id: String { rawValue }

    var label: String {
        switch self {
        case .transactional: return "Transactional"
        case .otp:           return "OTP"
        case .personal:      return "Personal"
        case .government:    return "Government"
        case .service:       return "Service"
        case .promotional:   return "Promotional"
        case .uncategorized: return "Other"
        }
    }

    var color: Color {
        switch self {
        case .transactional: return .haloGreen
        case .otp:           return .haloAmber
        case .personal:      return .haloAccent
        case .government:    return .haloPurple
        case .service:       return .haloCyan
        case .promotional:   return .haloText2
        case .uncategorized: return .haloText2
        }
    }

    var icon: String {
        switch self {
        case .transactional: return "indianrupeesign.circle.fill"
        case .otp:           return "key.fill"
        case .personal:      return "person.fill"
        case .government:    return "building.columns.fill"
        case .service:       return "shippingbox.fill"
        case .promotional:   return "megaphone.fill"
        case .uncategorized: return "text.bubble.fill"
        }
    }
}

/// A device that syncs SMS.
struct SMSDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String       // "Pixel 8"
    let platform: String   // "android" / "ios"
    var iconName: String { platform == "ios" ? "iphone" : "candybarphone" }
}

/// A SIM line (own number + carrier) on a device.
struct SMSLine: Identifiable, Hashable, Sendable {
    let id: String
    let deviceId: String
    let label: String       // "Personal"
    let ownNumber: String   // "+91 98765 43210"
    let carrier: String     // "Airtel"
    let subscriptionId: Int
    /// Per-line sync toggle (D29). Stored in the line registry as `syncEnabled`;
    /// a disabled line is skipped by the phone's reader/uploader. Default on.
    var syncEnabled: Bool = true
}

/// A single message (already decrypted for the console).
struct SMSMessage: Identifiable, Hashable, Sendable {
    let id: String
    let lineId: String
    let contactNumber: String   // the other party
    let body: String
    let date: Date
    let category: SMSCategory
    var read: Bool
}

/// A per-line conversation thread (F-044 D21 — thread identity = device+line+contact).
struct SMSThread: Identifiable, Hashable, Sendable {
    let id: String              // hash(lineId | contactNumber)
    let lineId: String
    let contactNumber: String
    var messages: [SMSMessage]

    var lastMessage: SMSMessage? { messages.max(by: { $0.date < $1.date }) }
    var lastDate: Date { lastMessage?.date ?? .distantPast }
    var unreadCount: Int { messages.filter { !$0.read }.count }
    /// Dominant category (the thread's newest message's category is a good proxy).
    var category: SMSCategory { lastMessage?.category ?? .uncategorized }
}

// MARK: - Classifier (pack-driven, F-044 §7.4)

/// First-match-wins classifier: otp → personal → government → `-P` shortcut → transactional → service → promotional →
/// DLT suffix → uncategorized. The keyword lists are NOT in this file: they are the `classifier` section of
/// `india-bank-sms.v1.json`, the same file the Android `SmsClassifier` reads (F-044 §7.4 puts the exact lists in the pack),
/// so the desktop and the phone cannot disagree on a list. This replaces an older compact hard-coded port whose shorter
/// lists classified two fixtures differently from the phone.
enum SmsClassifier {
    static func classify(sender: String, body: String, pack: PatternPack = .indiaDefault) -> SMSCategory {
        let k = pack.classifier
        let s = sender.uppercased()
        let b = body.uppercased()
        let bRange = NSRange(location: 0, length: (b as NSString).length)

        // 1. OTP
        if k.otpKeywords.contains(where: { b.contains($0) }) || k.otpNumber.firstMatch(in: b, range: bRange) != nil { return .otp }
        // 2. Personal: sender is a bare phone number — no letters, only [0-9 +()-.], digit count within the pack's range.
        if isPersonalSender(sender, k) { return .personal }
        // 3. Government
        if k.govSenders.contains(where: { s.contains($0) }) || k.govKeywords.contains(where: { b.contains($0) }) { return .government }
        // -P promotional DLT header shortcut (before the transactional content check).
        if s.hasSuffix("-P") { return .promotional }
        // 4. Transactional
        if k.transactionalStrong.contains(where: { b.contains($0) }) { return .transactional }
        if k.moneyTokens.contains(where: { b.contains($0) }) && k.transactionalVerbs.contains(where: { b.contains($0) }) { return .transactional }
        // 5. Service  6. Promotional
        if k.serviceKeywords.contains(where: { b.contains($0) }) { return .service }
        if k.promoKeywords.contains(where: { b.contains($0) }) { return .promotional }
        // 7. DLT suffix fallback
        if s.hasSuffix("-T") { return .transactional }
        if s.hasSuffix("-S") { return .service }
        if s.hasSuffix("-G") { return .government }
        return .uncategorized
    }

    private static func isPersonalSender(_ sender: String, _ k: ClassifierRules) -> Bool {
        if sender.isEmpty || sender.contains(where: { $0.isLetter }) { return false }
        let allowed: Set<Character> = [" ", "+", "(", ")", "-", "."]
        if !sender.allSatisfy({ $0.isASCII && $0.isNumber || allowed.contains($0) }) { return false }
        let digits = sender.filter { $0.isASCII && $0.isNumber }.count
        return (k.personalDigitsMin...k.personalDigitsMax).contains(digits)
    }
}
