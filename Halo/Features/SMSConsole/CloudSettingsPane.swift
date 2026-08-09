import SwiftUI

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
        !newPass.isEmpty && newPass == confirmPass
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                notificationsSection
                linesSection
                devicesSection
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

    // MARK: Devices (D28 per-device wipe)

    @ViewBuilder private var devicesSection: some View {
        if !client.devices.isEmpty {
            section("Devices", "Retire a phone — removes its entire synced subtree.") {
                ForEach(client.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.iconName).foregroundColor(.haloText2).frame(width: 20)
                        Text(device.name).font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText)
                        Spacer()
                        Button { pending = .wipeDevice(device) } label: {
                            Label("Wipe", systemImage: "trash").font(HaloFont.body(11)).foregroundColor(.haloRed)
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    if device.id != client.devices.last?.id { Divider().background(Color.haloBorder) }
                }
            }
        }
    }

    // MARK: Re-key (D24)

    private var rekeySection: some View {
        section("Re-key (rotate passphrase)", "Set a new encryption passphrase. This wipes the cloud SMS and your devices re-sync under the new key — no data is lost. Also use this if you forgot the old passphrase.") {
            secureField("New passphrase", $newPass)
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
        default: return "Wipe synced data?"
        }
    }

    private func confirmVerb(_ action: PendingAction) -> String {
        switch action {
        case .rekey: return "Re-key & wipe"
        case .disconnect: return "Disconnect"
        default: return "Wipe"
        }
    }

    private func confirmMessage(_ action: PendingAction) -> String {
        switch action {
        case .wipeAll: return "Removes all synced messages and devices from your cloud. Originals on your phone are untouched; devices can re-sync."
        case .wipeDevice(let d): return "Removes “\(d.name)” and all its synced messages from your cloud."
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
        case .rekey(let pass):    run { await client.rekey(newPassphrase: pass); newPass = ""; confirmPass = "" }
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
