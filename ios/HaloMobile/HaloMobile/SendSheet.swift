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

/// A device as a grid tile (icon, name, one line).
struct PeerTile: View {
    let peer: Peer
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 26)).foregroundColor(selected ? .haloAccent : .haloText2)
            Text(peer.alias).font(.system(size: 14, weight: .semibold)).foregroundColor(.haloText).lineLimit(1)
            Text(peer.info.deviceModel ?? peer.info.deviceType ?? "device").font(.system(size: 11)).foregroundColor(.haloText3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Color.haloAccent.opacity(0.14) : Color.haloSurface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.haloAccent.opacity(0.6) : Color.haloBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// The send sheet: the items, a device grid, one big Send button. Reached from the Share
/// extension, the file picker and the photo picker alike. **Nothing is sent until the person
/// has chosen a device here and tapped Send.**
struct SendSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDiscard = false

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 10)]

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
                        HaloPrimaryButton(title: "Done") { model.dismissTransferResult() }
                            .accessibilityIdentifier("send.done")
                    }
                }
                .padding(16)
            }
            .background(Color.haloBackground)
            .navigationTitle(ShareStrings.send)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing the sheet keeps the selection (a card on the Share tab brings it back).
                    Button("Close") { model.showSendSheet = false }.accessibilityIdentifier("send.close")
                }
            }
            .confirmationDialog(ShareStrings.discardTitle, isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { model.discardOutbox() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text(ShareStrings.discardDetail)
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
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(outbox.title)
                    Spacer()
                    HaloChip(text: "\(outbox.files.count) · \(Bytes.string(outbox.totalBytes))", systemImage: "tray.full", tint: .haloAccent)
                    HaloChip(text: ShareStrings.notSentYet, tint: .haloAmber)
                }
                ForEach(Array(outbox.files.prefix(4).enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill").foregroundColor(.haloAccent)
                        Text(file.name).font(.system(size: 13, weight: .medium)).foregroundColor(.haloText).lineLimit(1)
                        Spacer()
                        Text(Bytes.string(file.size)).font(.system(size: 11)).foregroundColor(.haloText3)
                    }
                    .accessibilityIdentifier("send.item.\(file.name)")
                }
                if outbox.files.count > 4 {
                    Text("+ \(outbox.files.count - 4) more").font(.system(size: 11)).foregroundColor(.haloText3)
                }
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(spacing: 8) {
            HStack {
                SectionLabel(ShareStrings.sendTo)
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Scan")
                        .accessibilityIdentifier("send.scan")
                }
            }
            if !model.localNetworkExplained { LocalNetworkExplainer() }
            else if model.localNetwork == .denied { LocalNetworkDeniedCard() }

            if model.peers.isEmpty {
                HaloCard {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundColor(.haloText3)
                        Text(model.isScanning ? "Looking…" : "No devices").font(.system(size: 13)).foregroundColor(.haloText3)
                    }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.peers) { peer in
                        Button { model.selectedPeerID = peer.id } label: { PeerTile(peer: peer, selected: model.selectedPeerID == peer.id) }
                            .buttonStyle(.plain)
                            .disabled(model.transfer.isBusy)
                            .accessibilityIdentifier("send.peer.\(peer.alias)")
                    }
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
                        HStack {
                            Text(name).font(.system(size: 13, weight: .medium)).foregroundColor(.haloText).lineLimit(1)
                            Spacer()
                            HaloInfoButton(title: ShareStrings.send, message: ShareStrings.sendingInfo)
                        }
                        ProgressView(value: Double(overallSent), total: Double(max(overallTotal, 1))).tint(.haloAccent)
                        Text("\(Bytes.string(sent)) / \(Bytes.string(total))").font(.system(size: 11)).foregroundColor(.haloText3)
                    }
                }
            case .finished, .failed:
                resultCard
            }

            if model.transfer.isBusy {
                Button(role: .destructive) { model.cancelSend() } label: { Label("Cancel", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.bordered).accessibilityIdentifier("send.cancel")
            } else {
                HaloPrimaryButton(title: model.selectedPeer.map { "Send to \($0.alias)" } ?? ShareStrings.chooseDevice,
                                  systemImage: "paperplane.fill") {
                    if let id = model.selectedPeerID { model.sendOutbox(to: id) }
                }
                .disabled(model.selectedPeer == nil)
                .accessibilityIdentifier("send.confirm")

                Button(role: .destructive) { confirmDiscard = true } label: { Text("Discard").frame(minHeight: 44) }
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
            HStack(spacing: 10) {
                Image(systemName: "wifi").foregroundColor(.haloAccent)
                Text(ShareStrings.localNetwork).font(.system(size: 14, weight: .semibold)).foregroundColor(.haloText)
                HaloInfoButton(title: ShareStrings.localNetworkInfoTitle, message: ShareStrings.localNetworkInfo)
                Spacer()
                Button("Allow") { model.continueLocalNetworkSetup() }
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
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").foregroundColor(.haloAmber)
                Text(ShareStrings.localNetworkOff).font(.system(size: 14, weight: .semibold)).foregroundColor(.haloAmber)
                HaloInfoButton(title: ShareStrings.localNetworkInfoTitle, message: ShareStrings.localNetworkDeniedInfo)
                Spacer()
                Button("Settings") { model.openSystemSettings() }
                    .buttonStyle(.bordered).accessibilityIdentifier("localnet.openSettings")
            }
        }
        .accessibilityIdentifier("localnet.denied")
    }
}
