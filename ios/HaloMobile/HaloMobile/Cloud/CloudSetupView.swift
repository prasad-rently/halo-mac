import SwiftUI
import HaloCloudKit

/// Settings → Cloud. A stepper card: (1) code → (2) passphrase → paired status. Explanations are behind (i).
struct CloudSetupView: View {
    @EnvironmentObject var cloud: CloudModel
    @State private var scanning = false
    @State private var confirmUnpair = false
    @FocusState private var focus: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if cloud.isPaired { pairedCard; DatabaseCheckCard() } else { stepper }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.haloBackground)
        .navigationTitle(CloudStrings.cloud)
        .toolbar { ToolbarItem(placement: .primaryAction) { info } }
        .sheet(isPresented: $scanning) {
            ZStack(alignment: .topTrailing) {
                QRScannerView { code in cloud.codeText = code; scanning = false; cloud.submitCode() }.ignoresSafeArea()
                Button("Close") { scanning = false }.padding().foregroundColor(.white)
            }
        }
        .confirmationDialog(CloudStrings.unpairConfirmTitle, isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button(CloudStrings.unpairConfirmButton, role: .destructive) { cloud.unpair() }
            Button(CloudStrings.cancel, role: .cancel) {}
        } message: { Text(CloudStrings.unpairConfirmMessage) }
    }

    private var info: some View {
        HaloInfoSheet(title: "About Cloud") {
            InfoLine(icon: "lock.shield", text: "Everything is end-to-end encrypted with your passphrase. Your own Firebase only ever holds ciphertext.")
            InfoLine(icon: "key", text: "The passphrase is never stored. This iPhone keeps only the derived key, in the Keychain, on this device only.")
            InfoLine(icon: "message", text: "iOS can't read SMS. This iPhone shows messages your Android phone synced, read-only.")
            InfoLine(icon: "doc.on.clipboard", text: "iOS has no background clipboard access. Send is manual, and syncing runs while Halo is open.")
        }
    }

    // MARK: Stepper

    private var stepper: some View {
        VStack(spacing: 14) {
            HaloCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        stepDot(1, done: cloud.parsed != nil, active: cloud.parsed == nil)
                        Rectangle().fill(Color.haloBorder).frame(height: 1)
                        stepDot(2, done: false, active: cloud.parsed != nil)
                    }
                    if let p = cloud.parsed { passphraseStep(p) } else { codeStep }
                }
            }
            if let e = cloud.error {
                HaloChip(text: e, icon: "exclamationmark.triangle.fill", color: .haloRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloud.error")
            }
        }
    }

    private func stepDot(_ n: Int, done: Bool, active: Bool) -> some View {
        ZStack {
            Circle().fill(done ? Color.haloGreen : (active ? Color.haloAccent : Color.haloSurface2)).frame(width: 26, height: 26)
            if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.black) }
            else { Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundColor(active ? .white : .haloText3) }
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CloudStrings.pairTitle).font(.system(size: 17, weight: .semibold)).foregroundColor(.haloText)
                Text(CloudStrings.pairSubtitle).font(.system(size: 12)).foregroundColor(.haloText3)
            }
            TextField("", text: $cloud.codeText, prompt: Text(CloudStrings.pairingCode).foregroundColor(.haloText3), axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus)
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.haloSurface2))
                .accessibilityIdentifier("cloud.code")
            HStack(spacing: 8) {
                chipButton(CloudStrings.paste, "doc.on.clipboard") { if let s = UIPasteboard.general.string { cloud.codeText = s } }
                if QRScannerView.isAvailable { chipButton(CloudStrings.scan, "qrcode.viewfinder") { scanning = true } }
                Spacer()
            }
            HaloPrimaryButton(title: CloudStrings.continue, enabled: !cloud.codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                focus = false; cloud.submitCode()
            }
            .accessibilityIdentifier("cloud.continue")
        }
    }

    private func chipButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { HaloChip(text: title, icon: icon, color: .haloAccent).frame(minHeight: 44) }
    }

    private func passphraseStep(_ p: PairingPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CloudStrings.passphrase).font(.system(size: 17, weight: .semibold)).foregroundColor(.haloText)
                    Text(p.auth.email).font(.system(size: 12)).foregroundColor(.haloText3)
                }
                Spacer()
                Button(CloudStrings.cancel) { cloud.cancelPairing() }.font(.system(size: 13)).foregroundColor(.haloText2)
            }
            SecureField("", text: $cloud.passphrase, prompt: Text(CloudStrings.passphrase).foregroundColor(.haloText3))
                .textContentType(.password).focused($focus)
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.haloSurface2))
                .accessibilityIdentifier("cloud.passphrase")
            if cloud.needsConfirmation {
                // D-01: an empty database cannot verify the passphrase, so it is typed twice and the user is told.
                HaloChip(text: CloudStrings.unverified, icon: "exclamationmark.triangle.fill", color: .haloAmber)
                Text(PairingConfirmation.notice).font(.system(size: 12)).foregroundColor(.haloAmber).fixedSize(horizontal: false, vertical: true)
                SecureField("", text: $cloud.confirmation, prompt: Text(CloudStrings.passphraseAgain).foregroundColor(.haloText3))
                    .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.haloSurface2))
                    .accessibilityIdentifier("cloud.passphrase2")
            }
            HaloPrimaryButton(title: cloud.busy ? "Connecting…" : CloudStrings.pair,
                              enabled: !cloud.busy && !cloud.passphrase.isEmpty && (!cloud.needsConfirmation || !cloud.confirmation.isEmpty)) {
                focus = false; cloud.connect()
            }
            .accessibilityIdentifier("cloud.pair")
        }
    }

    // MARK: Paired

    private var pairedCard: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Paired").font(.system(size: 17, weight: .semibold)).foregroundColor(.haloText)
                        Text(cloud.profileSummary?.host ?? "").font(.system(size: 12)).foregroundColor(.haloText3).lineLimit(1)
                    }
                    Spacer()
                    HaloStatusBadge(text: statusText, level: statusLevel)
                }
                HStack(spacing: 6) {
                    if let v = cloud.pairedVerified {
                        HaloChip(text: v ? CloudStrings.verified : CloudStrings.unverified, icon: v ? "checkmark.seal.fill" : "exclamationmark.triangle.fill", color: v ? .haloGreen : .haloAmber)
                    }
                    HaloChip(text: CloudStrings.worksWhileOpen, icon: "bolt.horizontal")
                }
                Button(role: .destructive) { confirmUnpair = true } label: {
                    Text(CloudStrings.unpair).font(.system(size: 14, weight: .semibold)).foregroundColor(.haloRed)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.haloRed.opacity(0.12)))
                }
                .accessibilityIdentifier("cloud.unpair")
            }
        }
    }

    private var statusText: String {
        switch cloud.sms.connection { case .live: return "Synced"; case .connecting: return "Connecting"; case .offline: return "Offline"; case .failed: return "Problem" }
    }
    private var statusLevel: HaloStatusBadge.Level {
        switch cloud.sms.connection { case .live: return .good; case .connecting: return .idle; case .offline: return .warn; case .failed: return .bad }
    }
}

// MARK: - F-057 "Check my database"

struct DatabaseCheckCard: View {
    @EnvironmentObject var cloud: CloudModel
    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(CloudStrings.checkDatabase).font(.system(size: 17, weight: .semibold)).foregroundColor(.haloText)
                    Spacer()
                    HaloInfoSheet(title: CloudStrings.checkDatabase) {
                        InfoLine(icon: "checklist", text: "Writes, reads back and deletes a small test entry under each folder Halo uses (meta, devices, sms, clipboard) and tells you which one your rules refuse.")
                        InfoLine(icon: "globe", text: "It also checks that your database does not answer people who are not signed in.")
                    }
                }
                if let r = cloud.report {
                    ForEach(r.items.indices, id: \.self) { i in row(r.items[i]) }
                }
                HaloPrimaryButton(title: cloud.checking ? "Checking…" : (cloud.report == nil ? "Run check" : "Run again"), icon: "stethoscope", enabled: !cloud.checking) { cloud.runCheck() }
                    .accessibilityIdentifier("cloud.runCheck")
            }
        }
    }

    private func row(_ item: DatabaseCheckItem) -> some View {
        let level: HaloStatusBadge.Level = { switch item.status { case .pass: return .good; case .warn: return .warn; case .fail: return .bad; case .skipped: return .idle } }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack { Text(item.title).font(.system(size: 14, weight: .medium)).foregroundColor(.haloText); Spacer()
                     HaloStatusBadge(text: label(item.status), level: level) }
            if item.status == .fail || item.status == .warn {
                Text(item.detail).font(.system(size: 12)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
                if let fix = item.fix { Text(fix).font(.system(size: 12)).foregroundColor(.haloAmber).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cloud.check.\(item.kind)")
    }

    private func label(_ s: DatabaseCheckStatus) -> String {
        switch s { case .pass: return "OK"; case .warn: return "Warning"; case .fail: return "Problem"; case .skipped: return "Skipped" }
    }
}

// MARK: - Share-tab status card (replaces the old "Not yet" rows)

struct CloudStatusCard: View {
    @EnvironmentObject var cloud: CloudModel
    var body: some View {
        Button { cloud.wantsSetup = true } label: {
            HaloCard {
                HStack(spacing: 12) {
                    Image(systemName: cloud.isPaired ? "icloud.fill" : "icloud.slash").font(.system(size: 22)).foregroundColor(cloud.isPaired ? .haloAccent : .haloText3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CloudStrings.cloud).font(.system(size: 15, weight: .semibold)).foregroundColor(.haloText)
                        Text(cloud.isPaired ? "Messages · Clipboard" : "SMS viewer · Clipboard").font(.system(size: 12)).foregroundColor(.haloText3)
                    }
                    Spacer()
                    if cloud.isPaired { HaloStatusBadge(text: cloud.sms.connection == .live ? "Synced" : "…", level: cloud.sms.connection == .live ? .good : .idle) }
                    else { HaloChip(text: "Set up", icon: "arrow.right", color: .haloAccent) }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("share.cloudFeatures")
    }
}
