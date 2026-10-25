import SwiftUI

// MARK: - CloudSetupView  (F-044)
//
// Manual "connect your Firebase" setup for Halo desktop (BYOB). The user pastes
// their own Firebase config + Email/Password auth + an E2E passphrase. This is
// the runtime-config path (no rebuild). The assisted auto-provisioning flow
// (firebase-setup.md §5) is a later addition.

struct CloudSetupView: View {
    @ObservedObject var client: SMSSyncClient
    @Environment(\.dismiss) private var dismiss

    // Firebase config
    @State private var apiKey = ""
    @State private var projectID = ""
    @State private var googleAppID = ""
    @State private var gcmSenderID = ""
    @State private var databaseURL = ""
    // Auth
    @State private var email = ""
    @State private var password = ""
    // E2E
    @State private var passphrase = ""
    /// Set when the OS RNG fails while creating a salt — surfaced instead of ever
    /// connecting with a zero salt (review finding 1).
    @State private var keyError: String?

    /// With no salt stored yet this connect *creates* the key, so the passphrase
    /// strength floor is enforced. With a salt already stored (paired from a phone)
    /// it only *unlocks* an existing key: a weak one is warned about, not blocked,
    /// since blocking would lock the user out without making anything safer.
    private var creatingKey: Bool { CloudConfigStore.shared.salt == nil }

    /// Connection fields only — the E2E passphrase is a local key, not part of the
    /// connection, so "Test connection" does not require it.
    private var canTest: Bool {
        !apiKey.isEmpty && !projectID.isEmpty && !googleAppID.isEmpty
            && !gcmSenderID.isEmpty && !databaseURL.isEmpty
            && !email.isEmpty && !password.isEmpty
    }

    private var canConnect: Bool {
        guard canTest, !passphrase.isEmpty else { return false }
        return !creatingKey || PassphrasePolicy.evaluate(passphrase).isAcceptable
    }

    private var isTesting: Bool {
        if case .testing = client.testResult { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusBanner
                testResultBanner
                section("1 · Firebase project", "From Firebase Console → Project settings → your app config. Halo stores this in the Keychain and configures the live app — no rebuild.") {
                    field("API key", $apiKey)
                    field("Project ID", $projectID)
                    field("App ID (googleAppID)", $googleAppID)
                    field("Messaging sender ID", $gcmSenderID)
                    field("Realtime Database URL", $databaseURL, placeholder: "https://<project>-default-rtdb.firebaseio.com")
                }
                section("2 · Sign in (Email/Password)", "The account both your Mac and phone use — creates the shared identity.") {
                    field("Email", $email)
                    secureField("Password", $password)
                }
                section("3 · Encryption passphrase", "End-to-end key. Your SMS are encrypted with this before upload — even your Firebase only stores ciphertext. Never leaves your devices.") {
                    secureField("Passphrase", $passphrase)
                    PassphraseStrengthHint(passphrase: passphrase, enforced: creatingKey)
                    if let keyError {
                        Text(keyError).font(HaloFont.body(10)).foregroundColor(.haloRed)
                    }
                }
                controls
                assistedNote
            }
            .padding(24)
            .frame(width: 520)
        }
        .background(Color.haloSurface)
    }

    // MARK: pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connect your Firebase").font(HaloFont.display(20)).foregroundColor(.haloText)
            Text("Halo is open-source and uses **your own** Firebase — no shared backend. Your data lives only in your account.")
                .font(HaloFont.body(12)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusBanner: some View {
        switch client.state {
        case .connecting:
            banner("Connecting…", .haloAmber, "arrow.triangle.2.circlepath")
        case .connected(let uid):
            banner("Connected · uid \(uid.prefix(8))…", .haloGreen, "checkmark.seal.fill")
        case .error(let msg):
            banner(msg, .haloRed, "exclamationmark.triangle.fill")
        case .unconfigured:
            EmptyView()
        }
    }

    @ViewBuilder private var testResultBanner: some View {
        switch client.testResult {
        case .testing:
            banner("Testing connection…", .haloAmber, "arrow.triangle.2.circlepath")
        case .success(let msg):
            banner(msg, .haloGreen, "checkmark.circle.fill")
        case .warning(let msg):
            banner(msg, .haloAmber, "exclamationmark.triangle.fill")
        case .failure(let msg):
            banner(msg, .haloRed, "xmark.octagon.fill")
        case .none:
            EmptyView()
        }
    }

    private func banner(_ text: String, _ color: Color, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).font(HaloFont.body(12)).foregroundColor(.haloText)
            Spacer()
        }
        .padding(10).background(color.opacity(0.12)).cornerRadius(8)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HaloGhostButton("Test connection", icon: "bolt.badge.checkmark") { test() }
                .disabled(!canTest || isTesting)
            HaloPrimaryButton("Connect", icon: "link") { connect() }
                .disabled(!canConnect || isTesting)
            if case .connected = client.state {
                HaloGhostButton("Seed sample data", icon: "sparkles") {
                    Task { await client.seedSampleData(); dismiss() }
                }
                HaloGhostButton("Done", icon: "checkmark") { dismiss() }
            } else {
                HaloGhostButton("Cancel") { dismiss() }
            }
        }
    }

    private var assistedNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundColor(.haloAccent)
            Text("Coming soon: one-click assisted setup (log in with Google → Halo provisions the project, rules & auth for you).")
                .font(HaloFont.body(11)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10).background(Color.haloSurface2).cornerRadius(8)
    }

    private func section<C: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
            Text(.init(subtitle)).font(HaloFont.body(11)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(HaloFont.body(10, weight: .semibold)).foregroundColor(.haloText2)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
                .padding(8).background(Color.haloSurface2).cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.haloBorder, lineWidth: 1))
        }
    }

    private func secureField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(HaloFont.body(10, weight: .semibold)).foregroundColor(.haloText2)
            SecureField("", text: text).textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
                .padding(8).background(Color.haloSurface2).cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.haloBorder, lineWidth: 1))
        }
    }

    private func currentConfig() -> FirebaseConfig {
        FirebaseConfig(apiKey: apiKey, projectID: projectID, googleAppID: googleAppID,
                       gcmSenderID: gcmSenderID, databaseURL: databaseURL, storageBucket: nil)
    }

    private func test() {
        let config = currentConfig()
        let auth = CloudAuthCredential(email: email, password: password)
        Task { await client.testConnection(config: config, auth: auth) }
    }

    private func connect() {
        let config = currentConfig()
        let auth = CloudAuthCredential(email: email, password: password)
        let store = CloudConfigStore.shared
        let salt: Data
        let iterations: Int
        if let existing = store.salt {
            // Keep the cost the existing key was derived with, or it derives a different key.
            salt = existing
            iterations = store.kdfIterations ?? CryptoService.legacyIterations
        } else {
            do { salt = try CryptoService.generateSalt() }
            catch { keyError = error.localizedDescription; return }
            iterations = CryptoService.defaultIterations
        }
        keyError = nil
        Task { await client.configureAndConnect(config: config, auth: auth, salt: salt,
                                                iterations: iterations, passphrase: passphrase) }
    }
}


// MARK: - PassphraseStrengthHint

/// One line under a passphrase field. `enforced` is true where the passphrase is
/// being *chosen* (the control is also disabled), false where an existing key is
/// merely being unlocked (advice only).
struct PassphraseStrengthHint: View {
    let passphrase: String
    let enforced: Bool

    var body: some View {
        let verdict = PassphrasePolicy.evaluate(passphrase)
        if !passphrase.isEmpty, let message = verdict.message {
            Text(enforced ? message : message + " Consider re-keying from Messages → Cloud settings.")
                .font(HaloFont.body(10))
                .foregroundColor(enforced ? .haloRed : .haloAmber)
                .fixedSize(horizontal: false, vertical: true)
        } else if passphrase.isEmpty && enforced {
            Text("At least \(PassphrasePolicy.minimumLength) characters. A few unrelated words works well.")
                .font(HaloFont.body(10)).foregroundColor(.haloText2)
        }
    }
}
