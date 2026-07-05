import Foundation

// MARK: - SMSSyncClient  (F-044)
//
// Real cloud data source for the SMS console. Configures the user's own Firebase
// (BYOB), signs in (Email/Password), reads `sms/{uid}` + `devices/{uid}`,
// decrypts the E2E fields with CryptoService, and builds the Device→Line→thread
// model the console renders.
//
// Schema (F-044 §7): sms/{uid}/{deviceId}/{messages,lines}, devices/{uid}/{deviceId}.
// address + body are AES-GCM ciphertext; structural fields are plaintext.

@MainActor
final class SMSSyncClient: ObservableObject {

    enum State: Equatable {
        case unconfigured
        case connecting
        case connected(uid: String)
        case error(String)
    }

    @Published private(set) var state: State = .unconfigured
    @Published private(set) var devices: [SMSDevice] = []
    @Published private(set) var lines: [SMSLine] = []
    @Published private(set) var threads: [SMSThread] = []

    private let store = CloudConfigStore.shared
    private let rtdb = FirebaseRTDBClient.shared
    private var crypto: CryptoService?

    var isConfigured: Bool { store.isConfigured }

    // MARK: Connect

    /// Connect using stored config/auth + a passphrase (from the user or Keychain cache).
    func connect(passphrase: String) async {
        guard let config = store.firebaseConfig, let auth = store.authCredential else {
            state = .unconfigured; return
        }
        state = .connecting
        do {
            try await rtdb.configure(config)
            let uid = try await rtdb.signIn(email: auth.email, password: auth.password)
            crypto = try store.makeCryptoService(passphrase: passphrase)
            state = .connected(uid: uid)
            await load(uid: uid)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Save a fresh config + auth + salt, then connect.
    func configureAndConnect(config: FirebaseConfig, auth: CloudAuthCredential,
                             salt: Data, passphrase: String) async {
        store.firebaseConfig = config
        store.authCredential = auth
        store.salt = salt
        await connect(passphrase: passphrase)
    }

    func refresh() async {
        if case let .connected(uid) = state { await load(uid: uid) }
    }

    func disconnect() {
        store.wipe()
        crypto = nil
        devices = []; lines = []; threads = []
        state = .unconfigured
    }

    // MARK: Load + decrypt

    private func load(uid: String) async {
        guard let crypto else { return }
        do {
            let devicesRaw = (try await rtdb.getValue(at: "devices/\(uid)")) as? [String: Any] ?? [:]
            let smsRaw = (try await rtdb.getValue(at: "sms/\(uid)")) as? [String: Any] ?? [:]

            var devs: [SMSDevice] = []
            var lns: [SMSLine] = []
            var msgs: [SMSMessage] = []

            for (deviceId, dv) in devicesRaw {
                let d = dv as? [String: Any] ?? [:]
                devs.append(SMSDevice(id: deviceId,
                                      name: d["name"] as? String ?? deviceId,
                                      platform: d["platform"] as? String ?? "android"))
            }

            for (deviceId, node) in smsRaw {
                let dict = node as? [String: Any] ?? [:]

                // lines
                if let linesDict = dict["lines"] as? [String: Any] {
                    for (subIdStr, lv) in linesDict {
                        let l = lv as? [String: Any] ?? [:]
                        let subId = Int(subIdStr) ?? (l["subscriptionId"] as? Int ?? -1)
                        let ownNumber = decryptOptional(l["ownNumberEnc"], crypto) ?? (l["ownNumber"] as? String ?? "Unknown")
                        lns.append(SMSLine(id: "\(deviceId)-\(subId)", deviceId: deviceId,
                                           label: l["label"] as? String ?? "SIM \(subId)",
                                           ownNumber: ownNumber,
                                           carrier: l["carrier"] as? String ?? "—",
                                           subscriptionId: subId))
                    }
                }

                // messages
                if let messagesDict = dict["messages"] as? [String: Any] {
                    for (msgId, mv) in messagesDict {
                        let m = mv as? [String: Any] ?? [:]
                        guard let addressEnc = m["addressEnc"] as? String,
                              let bodyEnc = m["bodyEnc"] as? String,
                              let address = try? crypto.decrypt(addressEnc),
                              let body = try? crypto.decrypt(bodyEnc) else { continue }
                        let subId = m["subscriptionId"] as? Int ?? 0
                        let dateMs = (m["date"] as? NSNumber)?.doubleValue ?? 0
                        msgs.append(SMSMessage(
                            id: msgId,
                            lineId: "\(deviceId)-\(subId)",
                            contactNumber: address,
                            body: body,
                            date: Date(timeIntervalSince1970: dateMs / 1000),
                            category: SmsClassifier.classify(sender: address, body: body),
                            read: (m["read"] as? Bool) ?? true))
                    }
                }
            }

            self.devices = devs.sorted { $0.name < $1.name }
            self.lines = lns.sorted { $0.deviceId + "\($0.subscriptionId)" < $1.deviceId + "\($1.subscriptionId)" }
            self.threads = Self.groupThreads(msgs)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func decryptOptional(_ value: Any?, _ crypto: CryptoService) -> String? {
        guard let s = value as? String else { return nil }
        return try? crypto.decrypt(s)
    }

    private static func groupThreads(_ messages: [SMSMessage]) -> [SMSThread] {
        var grouped: [String: [SMSMessage]] = [:]
        for m in messages { grouped["\(m.lineId)|\(m.contactNumber)", default: []].append(m) }
        return grouped.map { key, msgs in
            SMSThread(id: key, lineId: msgs[0].lineId, contactNumber: msgs[0].contactNumber, messages: msgs)
        }.sorted { $0.lastDate > $1.lastDate }
    }

    // MARK: Dev — seed sample data through the REAL pipeline (encrypt → your RTDB)

    /// Writes a few encrypted sample messages to the *user's own* Firebase so the
    /// round-trip (encrypt → RTDB → read → decrypt → display) can be seen without a
    /// phone. This is real cloud data, not in-memory mock.
    func seedSampleData() async {
        guard case let .connected(uid) = state, let crypto else { return }
        let deviceId = "desktop-demo"
        let subId = 0
        do {
            try await rtdb.setValue([
                "name": "Demo (desktop-seeded)", "platform": "android", "lastSeen": Date().timeIntervalSince1970 * 1000
            ], at: "devices/\(uid)/\(deviceId)")
            try await rtdb.setValue([
                "label": "Demo", "carrier": "TestCarrier",
                "ownNumberEnc": try crypto.encrypt("+91 90000 00000"), "subscriptionId": subId
            ], at: "sms/\(uid)/\(deviceId)/lines/\(subId)")

            let samples: [(String, String)] = [
                ("CP-INDUSB-S", "A/C *XX3833 debited by Rs 1250.00 via UPI. Avl Bal:8420.10 -IndusInd"),
                ("VM-AXISBK", "998231 is the OTP for your transaction. Do not share."),
                ("+919845012345", "Sent from a real encrypted round-trip ✅")
            ]
            for (i, s) in samples.enumerated() {
                let (sender, body) = s
                try await rtdb.setValue([
                    "addressEnc": try crypto.encrypt(sender),
                    "bodyEnc": try crypto.encrypt(body),
                    "subscriptionId": subId,
                    "date": (Date().timeIntervalSince1970 - Double(i * 300)) * 1000,
                    "read": i != 0, "schema": 1
                ], at: "sms/\(uid)/\(deviceId)/messages/demo_\(i)")
            }
            await refresh()
        } catch {
            state = .error("Seed failed: \(error.localizedDescription)")
        }
    }
}
