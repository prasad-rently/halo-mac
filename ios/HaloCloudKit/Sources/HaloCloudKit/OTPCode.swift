import Foundation

/// Finds a one-time code in an SMS so the viewer can offer a one-tap "Copy code". Deliberately conservative:
/// the message must look like an OTP message (the same cues the desktop classifier uses) AND contain a 4–8 digit
/// token that is not part of a longer number, an amount or a phone number. No match is better than copying the
/// wrong number.
public enum OTPCode {
    private static let cues = ["otp", "one time password", "one-time password", "verification code", "security code", "passcode", "login code", "do not share", "valid for"]
    private static let digits = try! NSRegularExpression(pattern: #"(?<![\d.,₹$+-])(\d{4,8})(?![\d.,]*\d)(?!\s*(?:rs|inr|usd|%))"#, options: [.caseInsensitive])

    public static func extract(from body: String) -> String? {
        let lower = body.lowercased()
        guard cues.contains(where: { lower.contains($0) }) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        for m in digits.matches(in: body, range: range) {
            guard let r = Range(m.range(at: 1), in: body) else { continue }
            // An amount ("Rs 5000", "INR 5000", "₹5000") is not a code.
            let head = body[..<r.lowerBound].suffix(5).lowercased().trimmingCharacters(in: .whitespaces)
            if head.hasSuffix("rs") || head.hasSuffix("rs.") || head.hasSuffix("inr") || head.hasSuffix("usd") { continue }
            return String(body[r])
        }
        return nil
    }
}
