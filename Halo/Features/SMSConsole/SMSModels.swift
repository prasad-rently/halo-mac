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

// MARK: - Classifier (compact port of Hamza's SmsClassifier, F-044 §7.4)

enum SmsClassifier {
    static func classify(sender: String, body: String) -> SMSCategory {
        let s = sender.uppercased()
        let b = body.uppercased()

        // 1. OTP
        if b.contains("OTP") || b.contains("ONE TIME PASSWORD") || b.contains("VERIFICATION CODE")
            || b.contains("DO NOT SHARE") || b.range(of: #"\b\d{4,8}\b\s+IS\s+(YOUR|THE)"#, options: .regularExpression) != nil {
            return .otp
        }
        // 2. Personal (sender is a bare phone number)
        if !sender.contains(where: { $0.isLetter }) {
            let digits = sender.filter(\.isNumber).count
            if (7...15).contains(digits) { return .personal }
        }
        // 3. Government
        for g in ["UIDAI", "NDMA", "EPFO", "INCOMETAX", "MYGOV", "COWIN", "-G"] where s.contains(g) { return .government }
        // -P promotional DLT header shortcut
        if s.hasSuffix("-P") { return .promotional }
        // 4. Transactional
        let txnStrong = ["DEBITED", "CREDITED", "WITHDRAWN", "UPI", "NEFT", "IMPS", "A/C", "AVL BAL", "TXN"]
        if txnStrong.contains(where: { b.contains($0) }) { return .transactional }
        let money = ["RS.", "RS ", "INR", "₹"]
        let verbs = ["PAID", "RECEIVED", "SPENT", "PAYMENT", "CHARGED"]
        if money.contains(where: { b.contains($0) }) && verbs.contains(where: { b.contains($0) }) { return .transactional }
        // 5. Service
        let service = ["DELIVERED", "OUT FOR DELIVERY", "SHIPPED", "ORDER", "BOOKING", "PNR", "TICKET", "DUE DATE", "STATEMENT"]
        if service.contains(where: { b.contains($0) }) { return .service }
        // 6. Promotional
        let promo = ["OFFER", "DISCOUNT", "SALE", "% OFF", "COUPON", "UNSUBSCRIBE", "CLICK HERE", "HURRY"]
        if promo.contains(where: { b.contains($0) }) { return .promotional }
        // 7. DLT suffix fallback
        if s.hasSuffix("-T") { return .transactional }
        if s.hasSuffix("-S") { return .service }
        if s.hasSuffix("-G") { return .government }
        return .uncategorized
    }
}
