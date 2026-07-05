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

    private var canConnect: Bool {
        !apiKey.isEmpty && !projectID.isEmpty && !googleAppID.isEmpty
            && !gcmSenderID.isEmpty && !databaseURL.isEmpty
            && !email.isEmpty && !password.isEmpty && !passphrase.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusBanner
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
            HaloPrimaryButton("Connect", icon: "link") { connect() }
                .disabled(!canConnect)
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

    private func connect() {
        let config = FirebaseConfig(apiKey: apiKey, projectID: projectID, googleAppID: googleAppID,
                                    gcmSenderID: gcmSenderID, databaseURL: databaseURL, storageBucket: nil)
        let auth = CloudAuthCredential(email: email, password: password)
        let salt = CloudConfigStore.shared.salt ?? CryptoService.generateSalt()
        Task { await client.configureAndConnect(config: config, auth: auth, salt: salt, passphrase: passphrase) }
    }
}
