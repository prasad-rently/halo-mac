import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit

// MARK: - CloudSettingsPane  (F-044 — D24 re-key, D28 wipe, D29 per-line toggle, D30 notifications)
//
// Management surface for a *connected* cloud account: new-SMS notification toggle,
// per-line sync toggles, wipe (all / per-device / per-line), re-key (wipe + rotate
// key), and disconnect. Opened from the console gear when connected; the initial
// "connect your Firebase" flow lives in CloudSetupView.

struct CloudSettingsPane: View {
    @ObservedObject var client: SMSSyncClient
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SMSSyncClient.notificationsDefaultsKey) private var notifications = true

    // Re-key fields
    @State private var newPass = ""
    @State private var confirmPass = ""

    @State private var pending: PendingAction?
    /// The pairing code holds the Firebase sign-in, so it is not even built until asked for (no Keychain read on
    /// every render), hides itself after 60 s (F-057 FR-S3), and is dropped again on Hide or on leaving the pane.
    @StateObject private var pairing = PairingCodeSession()
    @State private var busy = false

    /// A destructive action awaiting confirmation.
    private enum PendingAction: Identifiable {
        case wipeAll
        case wipeDevice(SMSDevice)
        case wipeLine(SMSLine)
        case rekey(String)
        case disconnect

        var id: String {
            switch self {
            case .wipeAll: return "all"
            case .wipeDevice(let d): return "dev-\(d.id)"
            case .wipeLine(let l): return "line-\(l.id)"
            case .rekey: return "rekey"
            case .disconnect: return "disconnect"
            }
        }
    }

    private var rekeyValid: Bool {
        PassphrasePolicy.evaluate(newPass).isAcceptable && newPass == confirmPass
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                notificationsSection
                DatabaseCheckSection()
                linesSection
                devicesSection
                pairingSection
                rekeySection
                dangerSection
            }
            .padding(24)
            .frame(width: 520)
            .disabled(busy)
        }
        .background(Color.haloSurface)
        .confirmationDialog(confirmTitle, isPresented: confirmBinding, presenting: pending) { action in
            Button(confirmVerb(action), role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(confirmMessage(action))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Cloud settings").font(HaloFont.display(20)).foregroundColor(.haloText)
                Spacer()
                if case .connected(let uid) = client.state {
                    HaloBadge(text: "uid \(uid.prefix(8))…", color: .haloGreen)
                }
                if busy { ProgressView().controlSize(.small) }
            }
            Text("Manage your end-to-end-encrypted SMS sync. Your phone is the source of truth — wiping or re-keying here never touches the original messages on the device.")
                .font(HaloFont.body(12)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Notifications (D30)

    private var notificationsSection: some View {
        section("Notifications", "Show a desktop alert for each newly-synced message.") {
            Toggle(isOn: $notifications) {
                Text("New-SMS notifications").font(HaloFont.body(12)).foregroundColor(.haloText)
            }
            .toggleStyle(.switch).tint(.haloAccent)
        }
    }

    // MARK: Lines (D29 per-line toggle + D28 per-line wipe)

    @ViewBuilder private var linesSection: some View {
        if !client.lines.isEmpty {
            section("SIM lines", "Turn sync off for a line to stop future uploads from that SIM (e.g. keep Work off). Wipe removes that line's synced messages.") {
                ForEach(client.lines) { line in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(line.label) · \(line.ownNumber)")
                                .font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText).lineLimit(1)
                            Text(line.carrier).font(HaloFont.body(10)).foregroundColor(.haloText2)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { line.syncEnabled },
                            set: { on in run { await client.setLineSync(line, enabled: on) } }))
                            .labelsHidden().toggleStyle(.switch).tint(.haloAccent)
                        Button { pending = .wipeLine(line) } label: {
                            Image(systemName: "trash").foregroundColor(.haloRed)
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    if line.id != client.lines.last?.id { Divider().background(Color.haloBorder) }
                }
            }
        }
    }

    // MARK: Devices (D28 per-device wipe; F-057 FR-S4 last-seen + retire)

    @ViewBuilder private var devicesSection: some View {
        if !client.devices.isEmpty {
            section("Devices", "Each phone that syncs to your cloud, and when it last did. Retire a phone you no longer use — this removes its entire synced subtree from your cloud (the messages on the phone itself are untouched).") {
                ForEach(client.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.iconName).foregroundColor(.haloText2).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText)
                            Text("Last seen: \(DeviceLastSeen.text(lastSeen: device.lastSeen))")
                                .font(HaloFont.body(10))
                                .foregroundColor(DeviceLastSeen.isStale(lastSeen: device.lastSeen) ? .haloAmber : .haloText2)
                        }
                        Spacer()
                        Button { pending = .wipeDevice(device) } label: {
                            Label("Retire", systemImage: "trash").font(HaloFont.body(11)).foregroundColor(.haloRed)
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    if device.id != client.devices.last?.id { Divider().background(Color.haloBorder) }
                }
            }
        }
    }

    // MARK: Phone pairing (F-049 US-1)

    private func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private var pairingSection: some View {
        section("Pair a phone", "Show a code your Halo phone app scans or pastes. It carries your Firebase sign-in so the phone can connect — never your encryption passphrase, which you type on the phone.") {
            if let code = pairing.code {
                HStack(alignment: .top, spacing: 16) {
                    if let img = qrImage(for: code) {
                        // CIQRCodeGenerator draws no quiet zone; a camera needs a light border or the dark
                        // window behind the image eats the code's edge. Larger, too: this payload is a dense code.
                        Image(nsImage: img).interpolation(.none).resizable().frame(width: 240, height: 240)
                            .padding(14).background(Color.white).cornerRadius(8)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(code).font(.system(size: 9, design: .monospaced)).foregroundColor(.haloText2)
                            .lineLimit(6).textSelection(.enabled)
                        HaloGhostButton("Copy code", icon: "doc.on.doc") {
                            // Concealed: the code carries the Firebase password, so it must not enter Halo's
                            // clipboard history or be synced to the cloud as an ordinary copy.
                            ClipboardPrivacy.writeConcealed(code)
                        }
                        Text("Anyone who sees this can sign in to your database (though not read your messages without the passphrase). Hide it when you're done.")
                            .font(HaloFont.body(10)).foregroundColor(.haloAmber)
                    }
                }
                HStack(spacing: 12) {
                    HaloGhostButton("Hide", icon: "eye.slash") { pairing.hide() }
                    HaloGhostButton("New code", icon: "arrow.clockwise") { pairing.show() }
                    // Whole-second countdown; TimelineView re-evaluates it each second without a timer of our own.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("Hides in \(pairing.secondsRemaining(at: ctx.date)) s")
                            .font(HaloFont.body(10)).foregroundColor(.haloText3)
                    }
                }
            } else {
                if pairing.unavailable {
                    Text("Connect your Firebase first — there is nothing to pair yet.")
                        .font(HaloFont.body(10)).foregroundColor(.haloText3)
                }
                if pairing.expired {
                    Text("The code was hidden after 60 seconds. Show it again to get a fresh one.")
                        .font(HaloFont.body(10)).foregroundColor(.haloText3)
                }
                HaloGhostButton("Show pairing code", icon: "qrcode") { pairing.show() }
            }
        }
        .onDisappear { pairing.hide() }
    }

    // MARK: Re-key (D24)

    private var rekeySection: some View {
        section("Re-key (rotate passphrase)", "Set a new encryption passphrase. This wipes the cloud SMS and your devices re-sync under the new key — no data is lost. Also use this if you forgot the old passphrase.") {
            secureField("New passphrase", $newPass)
            PassphraseStrengthHint(passphrase: newPass, enforced: true)
            secureField("Confirm passphrase", $confirmPass)
            if !confirmPass.isEmpty && newPass != confirmPass {
                Text("Passphrases don't match.").font(HaloFont.body(10)).foregroundColor(.haloRed)
            }
            HaloGhostButton("Re-key & wipe cloud", icon: "key.horizontal") {
                pending = .rekey(newPass)
            }
            .disabled(!rekeyValid)
        }
    }

    // MARK: Danger zone

    private var dangerSection: some View {
        section("Danger zone", "") {
            HStack(spacing: 12) {
                HaloGhostButton("Wipe everything", icon: "trash") { pending = .wipeAll }
                HaloGhostButton("Disconnect", icon: "xmark.circle") { pending = .disconnect }
                Spacer()
                HaloPrimaryButton("Done", icon: "checkmark") { dismiss() }
            }
        }
    }

    // MARK: Confirmation plumbing

    private var confirmBinding: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var confirmTitle: String {
        switch pending {
        case .rekey: return "Re-key and wipe cloud data?"
        case .disconnect: return "Disconnect and forget this cloud?"
        case .wipeDevice: return "Retire this phone?"
        default: return "Wipe synced data?"
        }
    }

    private func confirmVerb(_ action: PendingAction) -> String {
        switch action {
        case .rekey: return "Re-key & wipe"
        case .disconnect: return "Disconnect"
        case .wipeDevice: return "Retire"
        default: return "Wipe"
        }
    }

    private func confirmMessage(_ action: PendingAction) -> String {
        switch action {
        case .wipeAll: return "Removes all synced messages and devices from your cloud. Originals on your phone are untouched; devices can re-sync."
        case .wipeDevice(let d): return "Retires “\(d.name)”: removes it and all its synced messages from your cloud. The messages on the phone are untouched, and it can sync again if you pair it again."
        case .wipeLine(let l): return "Removes the “\(l.label)” line (\(l.ownNumber)) and its synced messages from your cloud."
        case .rekey: return "The cloud SMS store is wiped and re-encrypted under the new passphrase. Your devices re-sync from their inboxes. This can't be undone from here."
        case .disconnect: return "Clears the saved Firebase config, credential and key from this Mac's Keychain. Cloud data is left intact."
        }
    }

    private func perform(_ action: PendingAction) {
        pending = nil
        switch action {
        case .wipeAll:            run { await client.wipeAll() }
        case .wipeDevice(let d):  run { await client.wipeDevice(d.id) }
        case .wipeLine(let l):    run { await client.wipeLine(l) }
        case .rekey(let pass):    run { await client.rekey(newPassphrase: pass); newPass = ""; confirmPass = ""
                                        pairing.hide() }      // it carried the OLD salt — never leave a stale code on screen
        case .disconnect:         run { await client.disconnect(); dismiss() }
        }
    }

    private func run(_ op: @escaping () async -> Void) {
        busy = true
        Task { await op(); busy = false }
    }

    // MARK: Reused field/section builders (match CloudSetupView styling)

    private func section<C: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
            if !subtitle.isEmpty {
                Text(subtitle).font(HaloFont.body(11)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(14)
        .background(Color.haloSurface2.opacity(0.5)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
    }

    private func secureField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(HaloFont.body(10, weight: .semibold)).foregroundColor(.haloText2)
            SecureField("", text: text).textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
                .padding(8).background(Color.haloSurface2).cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.haloBorder, lineWidth: 1))
        }
    }
}
