import Foundation
import FirebaseDatabase   // DatabaseHandle (observer handles for teardown)

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

    /// Transient result of a pre-save "Test connection" probe (F-044). Independent
    /// of `state` so the user can validate a config without committing it.
    enum TestResult: Equatable {
        case testing
        case success(String)
        case failure(String)
    }

    @Published private(set) var state: State = .unconfigured
    @Published private(set) var devices: [SMSDevice] = []
    @Published private(set) var lines: [SMSLine] = []
    @Published private(set) var threads: [SMSThread] = []
    @Published private(set) var testResult: TestResult?

    private let store = CloudConfigStore.shared
    private let rtdb = FirebaseRTDBClient.shared
    private var crypto: CryptoService?

    // Live model, keyed for incremental `child_added` merges + dedup. Threads are
    // recomputed from `messagesById` whenever any of these change.
    private var devicesById: [String: SMSDevice] = [:]
    private var linesById: [String: SMSLine] = [:]
    private var messagesById: [String: SMSMessage] = [:]
    /// Devices we've already attached per-device (lines/messages) observers to.
    private var observedDevices: Set<String> = []
    /// (path, handle) pairs so every observer can be torn down on disconnect.
    private var observers: [(path: String, handle: DatabaseHandle)] = []
    /// Wall-clock at connect — messages newer than this are "live" and notifiable;
    /// older ones are historical backfill re-delivered by `child_added` on attach.
    private var connectedAt: Date = .distantFuture

    /// UserDefaults key for the D30 new-SMS notification toggle (default on).
    static let notificationsDefaultsKey = "smsNotificationsEnabled"

    var isConfigured: Bool { store.isConfigured }

    /// D30 — new-SMS desktop notifications, on unless explicitly disabled.
    var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.notificationsDefaultsKey) as? Bool ?? true
    }
    func setNotificationsEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.notificationsDefaultsKey)
    }

    // MARK: Connect

    /// Connect using stored config/auth + a passphrase (from the user or Keychain cache).
    func connect(passphrase: String) async {
        guard let config = store.firebaseConfig, let auth = store.authCredential else {
            state = .unconfigured; return
        }
        state = .connecting
        await stopObserving()
        resetModel()
        do {
            try await rtdb.configure(config)
            let uid = try await rtdb.signIn(email: auth.email, password: auth.password)
            crypto = try store.makeCryptoService(passphrase: passphrase)
            connectedAt = Date()
            state = .connected(uid: uid)
            await startObserving(uid: uid)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Validate a config + credential end-to-end (sign-in + `meta/{uid}` round-trip)
    /// without saving anything. The E2E passphrase is not needed — it's a local key,
    /// not part of the connection. Result is published on `testResult`.
    func testConnection(config: FirebaseConfig, auth: CloudAuthCredential) async {
        testResult = .testing
        do {
            try await rtdb.testConnection(config, email: auth.email, password: auth.password)
            testResult = .success("Connection OK — signed in and your database is reachable.")
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    /// Clear a stale test result (e.g. when the user edits a field).
    func clearTestResult() { testResult = nil }

    /// Save a fresh config + auth + salt, then connect.
    func configureAndConnect(config: FirebaseConfig, auth: CloudAuthCredential,
                             salt: Data, passphrase: String) async {
        testResult = nil
        store.firebaseConfig = config
        store.authCredential = auth
        store.salt = salt
        await connect(passphrase: passphrase)
    }

    func refresh() async {
        // Live observers keep the model current; Refresh forces a one-shot reconcile
        // (belt-and-suspenders if an observer was ever dropped, and paints
        // immediately after seeding).
        if case let .connected(uid) = state { await reconcile(uid: uid) }
    }

    func disconnect() async {
        await stopObserving()
        store.wipe()
        crypto = nil
        resetModel()
        state = .unconfigured
    }

    // MARK: Live streaming (child_added)

    /// Attach `child_added` observers so new devices, lines, and messages stream
    /// into the console live. `child_added` also re-delivers existing children on
    /// attach, so the initial paint comes from the same path — deduped by id.
    private func startObserving(uid: String) async {
        do {
            // New devices under `sms/{uid}` → attach per-device line/message observers.
            let smsHandle = try await rtdb.observeChildAdded(at: "sms/\(uid)") { [weak self] deviceId, _ in
                Task { @MainActor in self?.observeDevice(uid: uid, deviceId: deviceId) }
            }
            observers.append((path: "sms/\(uid)", handle: smsHandle))

            // Device metadata under `devices/{uid}`.
            let devHandle = try await rtdb.observeChildAdded(at: "devices/\(uid)") { [weak self] deviceId, value in
                Task { @MainActor in self?.mergeDevice(deviceId: deviceId, value: value) }
            }
            observers.append((path: "devices/\(uid)", handle: devHandle))
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Attach line + message observers for one device (idempotent per device).
    private func observeDevice(uid: String, deviceId: String) {
        guard observedDevices.insert(deviceId).inserted else { return }
        Task {
            do {
                let linesPath = "sms/\(uid)/\(deviceId)/lines"
                let linesHandle = try await rtdb.observeChildAdded(at: linesPath) { [weak self] subIdStr, value in
                    Task { @MainActor in self?.mergeLine(deviceId: deviceId, subIdStr: subIdStr, value: value) }
                }
                observers.append((path: linesPath, handle: linesHandle))

                let msgsPath = "sms/\(uid)/\(deviceId)/messages"
                let msgsHandle = try await rtdb.observeChildAdded(at: msgsPath) { [weak self] msgId, value in
                    Task { @MainActor in self?.mergeMessage(deviceId: deviceId, msgId: msgId, value: value) }
                }
                observers.append((path: msgsPath, handle: msgsHandle))
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func stopObserving() async {
        for o in observers { try? await rtdb.removeObserver(at: o.path, handle: o.handle) }
        observers.removeAll()
        observedDevices.removeAll()
    }

    private func resetModel() {
        devicesById.removeAll(); linesById.removeAll(); messagesById.removeAll()
        devices = []; lines = []; threads = []
    }

    /// Remove the per-device (lines/messages) observers for one device, leaving the
    /// top-level `sms/{uid}` + `devices/{uid}` observers in place. Lets the device
    /// re-attach cleanly (no duplicate observers) if it re-appears.
    private func removeDeviceObservers(_ deviceId: String) async {
        var kept: [(path: String, handle: DatabaseHandle)] = []
        for o in observers {
            if o.path.contains("/\(deviceId)/") {
                try? await rtdb.removeObserver(at: o.path, handle: o.handle)
            } else {
                kept.append(o)
            }
        }
        observers = kept
        observedDevices.remove(deviceId)
    }

    private func publishAll() { publishDevices(); publishLines(); publishThreads() }

    // MARK: Per-line sync toggle (D29)

    /// Persist a line's sync flag to the registry so the phone's uploader obeys it.
    /// The desktop is a viewer — existing synced messages remain visible; disabling
    /// only stops *future* uploads for that SIM.
    func setLineSync(_ line: SMSLine, enabled: Bool) async {
        guard case let .connected(uid) = state else { return }
        do {
            try await rtdb.setValue(enabled, at: "sms/\(uid)/\(line.deviceId)/lines/\(line.subscriptionId)/syncEnabled")
            if var l = linesById[line.id] { l.syncEnabled = enabled; linesById[line.id] = l }
            publishLines()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: Wipe (D28 — all / per-device / per-line)

    /// Wipe everything under the account (`sms/{uid}` + `devices/{uid}`) and restart
    /// observers so re-synced data streams back in.
    func wipeAll() async {
        guard case let .connected(uid) = state else { return }
        await stopObserving()
        do {
            try await rtdb.removeValue(at: "sms/\(uid)")
            try await rtdb.removeValue(at: "devices/\(uid)")
            resetModel()
        } catch {
            state = .error(error.localizedDescription)
        }
        await startObserving(uid: uid)
    }

    /// Wipe one device's subtree (retire an old phone).
    func wipeDevice(_ deviceId: String) async {
        guard case let .connected(uid) = state else { return }
        await removeDeviceObservers(deviceId)
        do {
            try await rtdb.removeValue(at: "sms/\(uid)/\(deviceId)")
            try await rtdb.removeValue(at: "devices/\(uid)/\(deviceId)")
            devicesById[deviceId] = nil
            linesById = linesById.filter { $0.value.deviceId != deviceId }
            messagesById = messagesById.filter { !$0.key.hasPrefix("\(deviceId)/") }
            publishAll()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Wipe a single SIM line: its registry entry + every message with that
    /// subscriptionId (read from the registry so undecryptable rows are removed too).
    func wipeLine(_ line: SMSLine) async {
        guard case let .connected(uid) = state else { return }
        do {
            let msgsRaw = (try await rtdb.getValue(at: "sms/\(uid)/\(line.deviceId)/messages")) as? [String: Any] ?? [:]
            for (rawId, mv) in msgsRaw {
                let m = mv as? [String: Any] ?? [:]
                if (m["subscriptionId"] as? Int ?? 0) == line.subscriptionId {
                    try await rtdb.removeValue(at: "sms/\(uid)/\(line.deviceId)/messages/\(rawId)")
                }
            }
            try await rtdb.removeValue(at: "sms/\(uid)/\(line.deviceId)/lines/\(line.subscriptionId)")
            messagesById = messagesById.filter { $0.value.lineId != line.id }
            linesById[line.id] = nil
            publishAll()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: Re-key (D24 — wipe + rotate key; phone is source of truth)

    /// Set a new E2E passphrase: rotate the salt, wipe the cloud SMS (there's no
    /// mixed-key ciphertext to reconcile), rebuild the crypto, and let devices
    /// re-sync from their inboxes under the new key. No data loss — the phone owns
    /// the originals. Doubles as key rotation.
    func rekey(newPassphrase: String) async {
        guard case let .connected(uid) = state else { return }
        await stopObserving()
        do {
            try await rtdb.removeValue(at: "sms/\(uid)")
            try await rtdb.removeValue(at: "devices/\(uid)")
            let newSalt = CryptoService.generateSalt()
            store.salt = newSalt
            crypto = try CryptoService(passphrase: newPassphrase, salt: newSalt)
            if store.cachedPassphrase != nil { store.cachedPassphrase = newPassphrase }
            connectedAt = Date()
            resetModel()
        } catch {
            state = .error(error.localizedDescription)
        }
        await startObserving(uid: uid)
    }

    // MARK: One-shot reconcile (manual Refresh)

    private func reconcile(uid: String) async {
        do {
            let devicesRaw = (try await rtdb.getValue(at: "devices/\(uid)")) as? [String: Any] ?? [:]
            let smsRaw = (try await rtdb.getValue(at: "sms/\(uid)")) as? [String: Any] ?? [:]

            for (deviceId, dv) in devicesRaw { mergeDevice(deviceId: deviceId, value: dv) }

            for (deviceId, node) in smsRaw {
                let dict = node as? [String: Any] ?? [:]
                if let linesDict = dict["lines"] as? [String: Any] {
                    for (subIdStr, lv) in linesDict { mergeLine(deviceId: deviceId, subIdStr: subIdStr, value: lv) }
                }
                if let messagesDict = dict["messages"] as? [String: Any] {
                    for (msgId, mv) in messagesDict { mergeMessage(deviceId: deviceId, msgId: msgId, value: mv) }
                }
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: Merge + decrypt (shared by streaming and reconcile)

    private func mergeDevice(deviceId: String, value: Any?) {
        let d = value as? [String: Any] ?? [:]
        devicesById[deviceId] = SMSDevice(id: deviceId,
                                          name: d["name"] as? String ?? deviceId,
                                          platform: d["platform"] as? String ?? "android")
        publishDevices()
    }

    private func mergeLine(deviceId: String, subIdStr: String, value: Any?) {
        guard let crypto else { return }
        let l = value as? [String: Any] ?? [:]
        let subId = Int(subIdStr) ?? (l["subscriptionId"] as? Int ?? -1)
        let ownNumber = decryptOptional(l["ownNumberEnc"], crypto) ?? (l["ownNumber"] as? String ?? "Unknown")
        let id = "\(deviceId)-\(subId)"
        linesById[id] = SMSLine(id: id, deviceId: deviceId,
                                label: l["label"] as? String ?? "SIM \(subId)",
                                ownNumber: ownNumber,
                                carrier: l["carrier"] as? String ?? "—",
                                subscriptionId: subId,
                                syncEnabled: l["syncEnabled"] as? Bool ?? true)
        publishLines()
    }

    private func mergeMessage(deviceId: String, msgId: String, value: Any?) {
        guard let crypto else { return }
        let m = value as? [String: Any] ?? [:]
        guard let addressEnc = m["addressEnc"] as? String,
              let bodyEnc = m["bodyEnc"] as? String,
              let address = try? crypto.decrypt(addressEnc),
              let body = try? crypto.decrypt(bodyEnc) else { return }
        let subId = m["subscriptionId"] as? Int ?? 0
        let dateMs = (m["date"] as? NSNumber)?.doubleValue ?? 0
        let uniqueId = "\(deviceId)/\(msgId)"   // raw keys can repeat across devices
        let date = Date(timeIntervalSince1970: dateMs / 1000)
        let category = SmsClassifier.classify(sender: address, body: body)
        let isNew = messagesById[uniqueId] == nil
        messagesById[uniqueId] = SMSMessage(
            id: uniqueId,
            lineId: "\(deviceId)-\(subId)",
            contactNumber: address,
            body: body,
            date: date,
            category: category,
            read: (m["read"] as? Bool) ?? true)
        publishThreads()

        // D30 — notify only for genuinely-new messages that arrived *after* connect
        // (skip the historical backfill `child_added` re-delivers on attach).
        if isNew, date >= connectedAt, notificationsEnabled {
            AlertManager.fireExternal(
                kindRaw: "sms_new",
                title: "New SMS · \(address)",
                body: body.count > 120 ? String(body.prefix(120)) + "…" : body)
        }
    }

    private func publishDevices() {
        devices = devicesById.values.sorted { $0.name < $1.name }
    }

    private func publishLines() {
        lines = linesById.values.sorted { $0.deviceId + "\($0.subscriptionId)" < $1.deviceId + "\($1.subscriptionId)" }
    }

    private func publishThreads() {
        threads = Self.groupThreads(Array(messagesById.values))
    }

    private func decryptOptional(_ value: Any?, _ crypto: CryptoService) -> String? {
        guard let s = value as? String else { return nil }
        return try? crypto.decrypt(s)
    }

    private static func groupThreads(_ messages: [SMSMessage]) -> [SMSThread] {
        // Per-line thread identity = (deviceId, subscriptionId, normalizedContact)
        // (D21 threadKey). Normalizing the contact merges the same number written in
        // different formats (spaces/dashes/"+91") into one thread; alphanumeric
        // sender IDs (e.g. "VM-AXISBK") are kept verbatim as their own thread.
        var grouped: [String: [SMSMessage]] = [:]
        for m in messages {
            grouped["\(m.lineId)|\(normalizeContact(m.contactNumber))", default: []].append(m)
        }
        return grouped.map { key, msgs in
            let byDate = msgs.sorted { $0.date < $1.date }
            // Display the most recent variant of the contact string.
            return SMSThread(id: key, lineId: byDate[0].lineId,
                             contactNumber: byDate.last!.contactNumber, messages: msgs)
        }.sorted { $0.lastDate > $1.lastDate }
    }

    /// Reduce a contact number to a stable grouping key: keep a leading `+` and all
    /// digits, drop separators. Returns the raw string unchanged when it carries no
    /// digits (alphanumeric DLT sender IDs), so those thread on their own.
    static func normalizeContact(_ raw: String) -> String {
        var out = ""
        for (i, ch) in raw.enumerated() {
            if ch.isNumber { out.append(ch) }
            else if ch == "+" && i == 0 { out.append(ch) }
        }
        return out.isEmpty ? raw : out
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
