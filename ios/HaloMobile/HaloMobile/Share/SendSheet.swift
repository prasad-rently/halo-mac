import SwiftUI
import HaloShareKit
import HaloShareStaging

/// The send sheet: the items, a device grid, one big Send button. Reached from the Share
/// extension, the file picker and the photo picker alike. **Nothing is sent until the person
/// has chosen a device here and tapped Send** — no device is ever pre-selected.
struct SendSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmDiscard = false
    @State private var showInfo = false

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: HaloLayout.cardSpacing), GridItem(.flexible())]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HaloLayout.sectionSpacing) {
                    if let outbox = model.outbox {
                        itemsCard(outbox)
                        devicesSection
                        actions(outbox)
                    } else {
                        // Sent and cleaned up; the result is all that's left.
                        resultCard
                        HaloPrimaryButton(HaloStrings.Share.done) { model.dismissTransferResult() }
                            .accessibilityIdentifier("send.done")
                    }
                }
                .padding(HaloLayout.screenPadding)
            }
            .haloScreen()
            .navigationTitle(ShareStrings.send)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing the sheet keeps the selection (a card on Share and Home brings it back).
                    Button("Close") { model.showSendSheet = false }.accessibilityIdentifier("send.close")
                }
            }
            .confirmationDialog(ShareStrings.discardTitle, isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { model.discardOutbox() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text(ShareStrings.discardDetail)
            }
            .haloInfoSheet(isPresented: $showInfo, title: ShareStrings.send, points: [
                HaloInfoPoint("hand.raised.fill", .haloGreen, "You choose", "Nothing is sent until you pick a device and tap Send."),
                HaloInfoPoint("app.badge", .haloAmber, "Keep Halo open", ShareStrings.sendingInfo),
            ])
            // A sender's consent prompt must be answerable even while this sheet is up.
            .sheet(item: $model.pendingOffer) { pending in
                ConsentSheet(offer: pending.offer).interactiveDismissDisabled()
            }
            .onAppear { if model.peers.isEmpty && !model.isScanning && model.localNetworkExplained { model.scan() } }
        }
        .preferredColorScheme(.dark)
        // A sheet sits above the root view, so the app-wide PrivacyShield does not cover it: hide the file
        // names here too whenever the app is not active (app-switcher snapshot).
        .overlay { if scenePhase != .active { PrivacyShield() } }
    }

    // MARK: Items

    private func itemsCard(_ outbox: OutboxSelection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(outbox.title, onInfo: { showInfo = true })
            HaloCard(accentTop: .haloAmber, padding: 0) {
                VStack(spacing: 0) {
                    HaloListRow(icon: "tray.full.fill", tint: .haloAmber,
                                title: "\(outbox.files.count) · \(Bytes.string(outbox.totalBytes))") {
                        HaloStatusBadge(ShareStrings.notSentYet, .warning)
                    }
                    ForEach(Array(outbox.files.prefix(4).enumerated()), id: \.offset) { _, file in
                        HaloRowDivider()
                        HaloListRow(icon: "doc.fill", tint: .haloAccent, title: file.name) {
                            Text(Bytes.string(file.size)).font(HaloFont.caption).foregroundColor(.haloText2).fixedSize()
                        }
                        .accessibilityIdentifier("send.item.\(file.name)")
                    }
                    if outbox.files.count > 4 {
                        Text("+ \(outbox.files.count - 4) more").font(HaloFont.caption).foregroundColor(.haloText3)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(ShareStrings.sendTo)
            if !model.localNetworkExplained { LocalNetworkExplainer() }
            else if model.localNetwork == .denied { LocalNetworkDeniedCard() }

            if model.peers.isEmpty {
                HaloCard {
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundColor(.haloText3).accessibilityHidden(true)
                        Text(model.isScanning ? HaloStrings.Share.scanning : HaloStrings.Share.noDevices)
                            .font(HaloFont.bodyMedium).foregroundColor(.haloText2)
                        Spacer(minLength: 0)
                        scanButton
                    }
                }
            } else {
                LazyVGrid(columns: columns, spacing: HaloLayout.cardSpacing) {
                    ForEach(model.peers) { peer in
                        // The tile shows the address the device was reached at, so a look-alike name is visible.
                        DeviceTile(peer: peer, isSelected: model.selectedPeerID == peer.id) {
                            HaloHaptics.selection()
                            model.selectedPeerID = peer.id
                        }
                        .disabled(model.transfer.isBusy)
                        .accessibilityIdentifier("send.peer.\(peer.alias)")
                    }
                }
                HStack { Spacer(); scanButton }
            }
            if let notice = model.notice {
                Text(notice).font(HaloFont.caption).foregroundColor(.haloAmber).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var scanButton: some View {
        if model.isScanning {
            ProgressView().controlSize(.small).frame(minWidth: HaloLayout.minTarget, minHeight: HaloLayout.minTarget)
        } else {
            HaloIconButton(icon: "arrow.clockwise", label: HaloStrings.Share.scan, tint: .haloAccent) { model.scan() }
                .accessibilityIdentifier("send.scan")
        }
    }

    // MARK: Actions

    private func actions(_ outbox: OutboxSelection) -> some View {
        VStack(spacing: 12) {
            switch model.transfer {
            case .idle: EmptyView()
            case .sending(let name, let sent, let total, let overallSent, let overallTotal):
                let progress = Double(overallSent) / Double(max(overallTotal, 1))
                HaloCard(accentTop: .haloAccent) {
                    HStack(spacing: 14) {
                        HaloRing(progress: progress, tint: .haloAccent, value: "\(Int(progress * 100))%", caption: nil, size: 64, lineWidth: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(HaloStrings.Share.sending) \(name)").font(HaloFont.headline).foregroundColor(.haloText).lineLimit(2)
                            Text("\(Bytes.string(sent)) / \(Bytes.string(total))").font(HaloFont.caption).foregroundColor(.haloText2)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue("\(Int(progress * 100)) percent")
                }
            case .finished, .failed:
                resultCard
            }

            if model.transfer.isBusy {
                HaloSecondaryButton(HaloStrings.Share.cancel, icon: "xmark", tint: .haloRed) { model.cancelSend() }
                    .accessibilityIdentifier("send.cancel")
            } else {
                HaloPrimaryButton(model.selectedPeer.map { "Send to \($0.alias)" } ?? ShareStrings.chooseDevice, icon: "paperplane.fill") {
                    if let id = model.selectedPeerID { model.sendOutbox(to: id) }
                }
                .disabled(model.selectedPeer == nil)
                .accessibilityIdentifier("send.confirm")

                HaloSecondaryButton("Discard", icon: "trash", tint: .haloRed) { confirmDiscard = true }
                    .accessibilityIdentifier("send.discard")
            }
        }
    }

    @ViewBuilder private var resultCard: some View {
        switch model.transfer {
        case .finished(let message):
            resultRow(message, state: .ok)
        case .failed(let why):
            resultRow(why, state: .error)
        default:
            EmptyView()
        }
    }

    private func resultRow(_ message: String, state: HaloState) -> some View {
        HaloCard(accentTop: state.color) {
            HStack(spacing: 10) {
                Image(systemName: state.symbol).foregroundColor(state.color).accessibilityHidden(true)
                Text(message).font(HaloFont.bodyMedium).foregroundColor(.haloText).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("share.result")
        }
    }
}

// MARK: - Local Network cards (MR-SH-4, MR-DI-5)

/// Shown *before* the OS permission prompt, which appears when the person taps Allow.
struct LocalNetworkExplainer: View {
    @EnvironmentObject var model: AppModel
    @State private var showInfo = false

    var body: some View {
        HaloCard {
            HStack(spacing: 10) {
                Image(systemName: "wifi").foregroundColor(.haloAccent).accessibilityHidden(true)
                Text(ShareStrings.localNetwork).font(HaloFont.headline).foregroundColor(.haloText)
                HaloInfoButton(title: ShareStrings.localNetworkInfoTitle) { showInfo = true }
                Spacer(minLength: 8)
                HaloPrimaryButton(HaloStrings.Share.allow, fullWidth: false) { model.continueLocalNetworkSetup() }
                    .accessibilityIdentifier("localnet.continue")
            }
        }
        .accessibilityIdentifier("localnet.explainer")
        .haloInfoSheet(isPresented: $showInfo, title: ShareStrings.localNetworkInfoTitle, points: [
            HaloInfoPoint("wifi", .haloAccent, "Why", ShareStrings.localNetworkInfo),
        ])
    }
}

struct LocalNetworkDeniedCard: View {
    @EnvironmentObject var model: AppModel
    @State private var showInfo = false

    var body: some View {
        HaloCard(accentTop: .haloAmber) {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").foregroundColor(.haloAmber).accessibilityHidden(true)
                Text(ShareStrings.localNetworkOff).font(HaloFont.headline).foregroundColor(.haloAmber)
                HaloInfoButton(title: ShareStrings.localNetworkInfoTitle) { showInfo = true }
                Spacer(minLength: 8)
                HaloSecondaryButton(HaloStrings.Share.openSettings, fullWidth: false) { model.openSystemSettings() }
                    .accessibilityIdentifier("localnet.openSettings")
            }
        }
        .accessibilityIdentifier("localnet.denied")
        .haloInfoSheet(isPresented: $showInfo, title: ShareStrings.localNetworkInfoTitle, points: [
            HaloInfoPoint("wifi.exclamationmark", .haloAmber, "Turned off", ShareStrings.localNetworkDeniedInfo),
        ])
    }
}
