import SwiftUI
import HaloShareKit
import HaloShareStaging

/// One row of the device list — shared by the Share tab and the send sheet.
struct PeerRow: View {
    let peer: Peer
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(selected ? .haloAccent : .haloText2).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.alias).font(.system(size: 15, weight: .medium)).foregroundColor(.haloText)
                Text("\(peer.info.deviceModel ?? peer.info.deviceType ?? "device") · \(peer.host)")
                    .font(.system(size: 11)).foregroundColor(.haloText3)
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundColor(.haloAccent) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.haloAccent.opacity(0.12) : Color.haloSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.haloAccent.opacity(0.5) : Color.haloBorder, lineWidth: 1))
    }

    private var icon: String {
        switch peer.info.deviceType {
        case "desktop": return "desktopcomputer"
        case "mobile": return "iphone"
        case "web": return "globe"
        case "headless", "server": return "server.rack"
        default: return "questionmark.circle"
        }
    }
}

/// "Ready to send": the items, the device picker, and the Send button. Reached from the Share
/// extension, the file picker and the photo picker alike. **Nothing is sent until the person
/// has chosen a device here and tapped Send.**
struct SendSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let outbox = model.outbox {
                        itemsCard(outbox)
                        devicesSection
                        actions(outbox)
                    } else {
                        // Sent and cleaned up; the result is all that's left.
                        resultCard
                        Button("Done") { model.dismissTransferResult() }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("send.done")
                    }
                }
                .padding(16)
            }
            .background(Color.haloBackground)
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing the sheet keeps the selection (a card on the Share tab brings it back).
                    Button("Close") { model.showSendSheet = false }.accessibilityIdentifier("send.close")
                }
            }
            .confirmationDialog("Discard these items?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { model.discardOutbox() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("They won't be sent. The originals are not touched.")
            }
            // A sender's consent prompt must be answerable even while this sheet is up.
            .sheet(item: $model.pendingOffer) { pending in
                ConsentSheet(offer: pending.offer).interactiveDismissDisabled()
            }
            .onAppear { if model.peers.isEmpty && !model.isScanning && model.localNetworkExplained { model.scan() } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Items

    private func itemsCard(_ outbox: OutboxSelection) -> some View {
        VStack(spacing: 8) {
            SectionLabel(outbox.title)
            HaloCard {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(outbox.files.enumerated()), id: \.offset) { _, file in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.fill").foregroundColor(.haloAccent)
                            Text(file.name).font(.system(size: 13, weight: .medium)).foregroundColor(.haloText).lineLimit(1)
                            Spacer()
                            Text(Bytes.string(file.size)).font(.system(size: 11)).foregroundColor(.haloText3)
                        }
                        .accessibilityIdentifier("send.item.\(file.name)")
                    }
                    Divider().overlay(Color.haloBorder)
                    Text("\(outbox.files.count) item\(outbox.files.count == 1 ? "" : "s") · \(Bytes.string(outbox.totalBytes))")
                        .font(.system(size: 11)).foregroundColor(.haloText3)
                }
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(spacing: 8) {
            HStack {
                SectionLabel("Send to")
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.scan() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityIdentifier("send.scan")
                }
            }
            if !model.localNetworkExplained { LocalNetworkExplainer() }
            else if model.localNetwork == .denied { LocalNetworkDeniedCard() }

            if model.peers.isEmpty {
                HaloCard {
                    Text(model.isScanning ? "Looking on your Wi-Fi…" : "No devices yet. Tap Scan, or add an address on the Share tab.")
                        .font(.system(size: 13)).foregroundColor(.haloText3)
                }
            } else {
                ForEach(model.peers) { peer in
                    Button { model.selectedPeerID = peer.id } label: { PeerRow(peer: peer, selected: model.selectedPeerID == peer.id) }
                        .buttonStyle(.plain)
                        .disabled(model.transfer.isBusy)
                        .accessibilityIdentifier("send.peer.\(peer.alias)")
                }
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 12)).foregroundColor(.haloAmber).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Actions

    private func actions(_ outbox: OutboxSelection) -> some View {
        VStack(spacing: 10) {
            switch model.transfer {
            case .idle: EmptyView()
            case .sending(let name, let sent, let total, let overallSent, let overallTotal):
                HaloCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sending \(name)").font(.system(size: 13, weight: .medium)).foregroundColor(.haloText)
                        ProgressView(value: Double(overallSent), total: Double(max(overallTotal, 1))).tint(.haloAccent)
                        Text("\(Bytes.string(sent)) of \(Bytes.string(total))").font(.system(size: 11)).foregroundColor(.haloText3)
                    }
                }
            case .finished, .failed:
                resultCard
            }

            if model.transfer.isBusy {
                Button(role: .destructive) { model.cancelSend() } label: { Label("Cancel", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).accessibilityIdentifier("send.cancel")
                Text("Keep Halo open until this finishes. If you leave, iOS gives it a short moment to wrap up.")
                    .font(.system(size: 11)).foregroundColor(.haloText3)
            } else {
                Button {
                    if let id = model.selectedPeerID { model.sendOutbox(to: id) }
                } label: {
                    Label(model.selectedPeer.map { "Send to \($0.alias)" } ?? "Choose a device to send", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedPeer == nil)
                .accessibilityIdentifier("send.confirm")

                Button(role: .destructive) { confirmDiscard = true } label: { Text("Discard") }
                    .accessibilityIdentifier("send.discard")
            }
        }
    }

    @ViewBuilder private var resultCard: some View {
        switch model.transfer {
        case .finished(let message):
            Label(message, systemImage: "checkmark.circle").font(.system(size: 13)).foregroundColor(.haloGreen)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("share.result")
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundColor(.haloRed)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("share.result")
        default:
            EmptyView()
        }
    }
}

// MARK: - Local Network cards (MR-SH-4, MR-DI-5)

/// Shown *before* the OS permission prompt, which appears when the person taps Continue.
struct LocalNetworkExplainer: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Allow Local Network access", systemImage: "wifi").font(.system(size: 14, weight: .semibold)).foregroundColor(.haloText)
                Text("To find your other devices, Halo looks for HaloShare and LocalSend on your Wi-Fi. iOS will ask you to allow this next. Nothing leaves your network.")
                    .font(.system(size: 12)).foregroundColor(.haloText2)
                Button("Continue") { model.continueLocalNetworkSetup() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("localnet.continue")
            }
        }
        .accessibilityIdentifier("localnet.explainer")
    }
}

struct LocalNetworkDeniedCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Local Network access is off", systemImage: "wifi.exclamationmark").font(.system(size: 14, weight: .semibold)).foregroundColor(.haloAmber)
                Text("Without it Halo can't see other devices, and they can't send to this one. Turn on Local Network for Halo in Settings → Privacy & Security → Local Network.")
                    .font(.system(size: 12)).foregroundColor(.haloText2)
                Button("Open Settings") { model.openSystemSettings() }
                    .buttonStyle(.bordered).accessibilityIdentifier("localnet.openSettings")
            }
        }
        .accessibilityIdentifier("localnet.denied")
    }
}
