import Foundation

// MARK: - Mock SMS data  (F-044 preview)
//
// Realistic seed data so the SMS console renders without a phone/Firebase.
// Two devices, dual-SIM lines, threads spanning every category. Bodies are
// representative Indian bank/UPI/OTP formats (from the Hamza reference corpus).

enum MockSMSData {

    static let devices: [SMSDevice] = [
        SMSDevice(id: "dev-pixel", name: "Pixel 8", platform: "android"),
        SMSDevice(id: "dev-iphone", name: "iPhone 15", platform: "ios")
    ]

    static let lines: [SMSLine] = [
        SMSLine(id: "line-personal", deviceId: "dev-pixel", label: "Personal",
                ownNumber: "+91 98765 43210", carrier: "Airtel", subscriptionId: 0),
        SMSLine(id: "line-work", deviceId: "dev-pixel", label: "Work",
                ownNumber: "+91 90123 45678", carrier: "Jio", subscriptionId: 1),
        SMSLine(id: "line-iphone", deviceId: "dev-iphone", label: "iPhone SIM",
                ownNumber: "+91 99887 76655", carrier: "Vi", subscriptionId: 0)
    ]

    /// Build threads by grouping seed messages per (line, contact).
    static func threads() -> [SMSThread] {
        var grouped: [String: [SMSMessage]] = [:]
        for m in seedMessages() {
            let key = "\(m.lineId)|\(m.contactNumber)"
            grouped[key, default: []].append(m)
        }
        return grouped.map { key, msgs in
            let first = msgs[0]
            return SMSThread(id: key, lineId: first.lineId,
                             contactNumber: first.contactNumber, messages: msgs)
        }
        .sorted { $0.lastDate > $1.lastDate }
    }

    // MARK: seed

    private static func seedMessages() -> [SMSMessage] {
        let now = Date()
        func t(_ minsAgo: Int) -> Date { now.addingTimeInterval(TimeInterval(-minsAgo * 60)) }

        // (lineId, sender, body, minutesAgo, read)
        let raw: [(String, String, String, Int, Bool)] = [
            // Personal SIM — bank (transactional)
            ("line-personal", "CP-INDUSB-S", "A/C *XX3833 debited by Rs 3984.10 on 05-Jul. Avl Bal:12295.63. Not you? Call 18602677777 -IndusInd", 8, false),
            ("line-personal", "CP-INDUSB-S", "INR 35,000.00 is credited to A/C XX3833 from SRILEKHA M via UPI. Avl Bal INR 47,295.63 -IndusInd", 220, true),
            ("line-personal", "JM-IDFCFB-S", "INR 285.48 spent on IDFC FIRST Card xx4021 at ZOMATO on 05-Jul. Avbl Limit: INR 214682.89", 45, false),
            // Personal SIM — OTP
            ("line-personal", "VM-AXISBK", "076790 is the OTP for txn of INR 504.00 on Axis Bank Card. Valid 10 min. Do not share.", 15, false),
            ("line-personal", "AD-AMAZON", "123456 is your Amazon OTP. Do not share it with anyone.", 300, true),
            // Personal SIM — a friend (personal)
            ("line-personal", "+919845012345", "Hey! Are we still on for dinner tonight at 8? 🍜", 120, false),
            ("line-personal", "+919845012345", "Cool, see you then. I'll book the table.", 95, true),
            // Personal SIM — service (delivery)
            ("line-personal", "VM-SWIGGY-S", "Your Swiggy order #4821 is out for delivery and will arrive in ~12 mins.", 30, true),
            ("line-personal", "AX-EKARTL-S", "Your Flipkart order will be delivered today by 7 PM. Track: http://fkrt.it/x9a2", 500, true),
            // Personal SIM — government
            ("line-personal", "VA-EPFOHO-G", "EPFO: Your PF contribution of Rs 5,400 for Jun-2026 has been credited to your account.", 1400, true),
            // Personal SIM — promotional
            ("line-personal", "VM-KOTAKB-P", "Still spending without rewards? Get the Kotak 811 credit card. Apply now! T&C apply.", 700, true),

            // Work SIM — bank (transactional)
            ("line-work", "VD-HDFCBK-S", "Txn Rs.522.00 On HDFC Bank Card 3974 At paytm on 05-Jul by UPI. Avl Bal Rs 1,04,220.00", 60, false),
            ("line-work", "VM-HDFCBK-T", "Sent Rs.250.00 From HDFC Bank A/C *3420 To IREEN via UPI. Ref 518402719283.", 180, true),
            // Work SIM — reminder (service)
            ("line-work", "AD-AXISBK-S", "Payment of INR 183 for Axis card is due on 12-Jul-26. Please pay to avoid charges.", 900, true),
            // Work SIM — OTP
            ("line-work", "JD-GITHUB", "GitHub: your verification code is 884213. It expires in 5 minutes.", 5, false),

            // iPhone SIM — bank + personal
            ("line-iphone", "AD-SBIINB-S", "Dear Customer, Rs 1,999.00 debited from A/c XX9021 on 05-Jul via UPI to NETFLIX. -SBI", 40, false),
            ("line-iphone", "+919845012345", "Sent you the file on the other number too 👍", 200, true),
            ("line-iphone", "VM-JIOMNY-P", "Recharge now & get 2GB extra data free! Limited time offer. Click bit.ly/jio-offer", 620, true),
        ]

        return raw.enumerated().map { idx, r in
            let (lineId, sender, body, minsAgo, read) = r
            return SMSMessage(id: "msg-\(idx)", lineId: lineId, contactNumber: sender,
                              body: body, date: t(minsAgo),
                              category: SmsClassifier.classify(sender: sender, body: body),
                              read: read)
        }
    }
}
