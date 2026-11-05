import SwiftUI
import UniformTypeIdentifiers
import HaloShareKit

/// Share — a radar of nearby devices, a big "Choose files" action, transfer progress, received files.
struct ShareView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: AppRouter
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var picking = false
    @State private var showAddSheet = false
    @State private var showReceivingInfo = false
    @State private var showDiscoveryInfo = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HaloLayout.sectionSpacing) {
                    thisDevice
                    noticeBanner
                    nearby
                    sendCard
                    received
                }
                .padding(HaloLayout.screenPadding)
            }
            .haloScreen()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(HaloStrings.Share.title)
            .navigationDestination(isPresented: $router.showInbox) { InboxView() }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty { model.send(urls) }
            }
            .sheet(isPresented: $showAddSheet) { AddAddressSheet().environmentObject(model) }
            .haloInfoSheet(isPresented: $showReceivingInfo, title: HaloStrings.Info.receivingTitle,
                           summary: HaloStrings.Info.receivingSummary, points: ShareInfo.receiving)
            .haloInfoSheet(isPresented: $showDiscoveryInfo, title: HaloStrings.Info.discoveryTitle,
                           summary: HaloStrings.Info.discoverySummary, points: ShareInfo.discovery)
            .onAppear { consumeScanRequest() }
            .onChange(of: router.scanOnShare) { _ in consumeScanRequest() }
            .onChange(of: model.peers.count) { _ in
                // A manually-added device landed: close the sheet.
                if showAddSheet { showAddSheet = false }
            }
        }
    }

    private func consumeScanRequest() {
        guard router.scanOnShare else { return }
        router.scanOnShare = false
        model.scan()
    }

    // MARK: This device

    private var thisDevice: some View {
        HaloCard {
            HStack(spacing: 12) {
                Image(systemName: "iphone").font(.system(.title3)).foregroundColor(.haloAccent)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.haloAccent.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.identity.alias).font(HaloFont.headline).foregroundColor(.haloText).lineLimit(2)
                    listenBadge
                }
                Spacer(minLength: 0)
                HaloIconButton(icon: "info.circle", label: "About receiving") { showReceivingInfo = true }
            }
        }
        .accessibilityIdentifier("share.thisDevice")
    }

    private var listenBadge: some View {
        switch model.listenState {
        case .listening(let port): return HaloStatusBadge("Ready · port \(port)", .ok)
        case .starting: return HaloStatusBadge("Starting…", .warning)
        case .stopped: return HaloStatusBadge("Not listening", .error)
        case .failed(let why): return HaloStatusBadge("Can't receive: \(why)", .error)
        }
    }

    // MARK: Notice

    @ViewBuilder private var noticeBanner: some View {
        if let notice = model.notice {
            HaloCard(accentTop: .haloAmber, padding: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.haloAmber).accessibilityHidden(true)
                    Text(notice).font(HaloFont.body).foregroundColor(.haloText).frame(maxWidth: .infinity, alignment: .leading)
                    HaloIconButton(icon: "xmark", label: HaloStrings.Share.dismiss) { model.notice = nil }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("share.notice")
        }
    }

    // MARK: Nearby (radar + device grid)

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: HaloLayout.cardSpacing), GridItem(.flexible())]
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HaloSectionHeader(HaloStrings.Share.nearbyDevices, onInfo: { showDiscoveryInfo = true })
                if model.isScanning {
                    HaloSecondaryButton(HaloStrings.Share.stop, icon: "stop.fill", fullWidth: false) { model.stopScan() }
                } else {
                    HaloSecondaryButton(HaloStrings.Share.scan, icon: "arrow.clockwise", tint: .haloAccent, fullWidth: false) { model.scan() }
                        .accessibilityIdentifier("share.scan")
                }
            }

            HaloCard {
                VStack(spacing: 6) {
                    HaloRadar(isScanning: model.isScanning, peerIDs: model.peers.map(\.id))
                        .frame(maxWidth: .infinity)
                    Text(radarCaption).font(HaloFont.bodyMedium)
                        .foregroundColor(model.peers.isEmpty && !model.isScanning ? .haloText2 : .haloText)
                    if model.peers.isEmpty && !model.isScanning {
                        Text(HaloStrings.Share.noDevicesHint).font(HaloFont.caption).foregroundColor(.haloText3)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            LazyVGrid(columns: columns, spacing: HaloLayout.cardSpacing) {
                ForEach(model.peers) { peer in
                    DeviceTile(peer: peer, isSelected: model.selectedPeerID == peer.id) {
                        HaloHaptics.selection()
                        model.selectedPeerID = peer.id
                    }
                    .accessibilityIdentifier("share.peer.\(peer.alias)")
                }
                AddTile { showAddSheet = true }
                    .accessibilityIdentifier("share.addTile")
            }
        }
    }

    private var radarCaption: String {
        if model.isScanning { return HaloStrings.Share.scanning }
        switch model.peers.count {
        case 0: return HaloStrings.Share.noDevices
        case 1: return "1 device nearby"
        default: return "\(model.peers.count) devices nearby"
        }
    }

    // MARK: Send / transfer

    private var sendCard: some View {
        HaloCard(accentTop: transferAccent) {
            VStack(alignment: .leading, spacing: 14) {
                switch model.transfer {
                case .idle:
                    targetRow
                case .sending(let name, let sent, let total, let overallSent, let overallTotal):
                    sendingRow(name: name, sent: sent, total: total, overallSent: overallSent, overallTotal: overallTotal)
                case .finished(let message):
                    resultRow(message, state: .ok)
                case .failed(let why):
                    resultRow(why, state: .error)
                }

                if !model.transfer.isBusy {
                    HaloPrimaryButton(HaloStrings.Share.chooseFiles, icon: "doc.badge.plus") {
                        model.dismissTransferResult(); picking = true
                    }
                    .disabled(model.selectedPeer == nil)
                    .accessibilityIdentifier("share.chooseFiles")

                    #if DEBUG
                    HaloSecondaryButton(HaloStrings.Share.sendTest, icon: "hammer") {
                        model.dismissTransferResult(); model.sendTestFile()
                    }
                    .disabled(model.selectedPeer == nil)
                    .accessibilityIdentifier("share.sendTest")
                    #endif
                }
            }
        }
    }

    private var transferAccent: Color? {
        switch model.transfer {
        case .sending: return .haloAccent
        case .finished: return .haloGreen
        case .failed: return .haloRed
        case .idle: return nil
        }
    }

    private var targetRow: some View {
        HStack(spacing: 12) {
            if let peer = model.selectedPeer {
                Image(systemName: DeviceTile.icon(for: peer)).foregroundColor(.haloAccent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.haloAccent.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HaloStrings.Share.sendTo.uppercased()).font(HaloFont.section).tracking(1.2).foregroundColor(.haloText3)
                    Text(peer.alias).font(HaloFont.headline).foregroundColor(.haloText).lineLimit(2)
                }
            } else {
                Image(systemName: "hand.point.up.left").foregroundColor(.haloText3)
                    .frame(width: 36, height: 36).accessibilityHidden(true)
                Text(HaloStrings.Share.chooseDeviceFirst).font(HaloFont.bodyMedium).foregroundColor(.haloText2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func sendingRow(name: String, sent: Int64, total: Int64, overallSent: Int64, overallTotal: Int64) -> some View {
        let progress = Double(overallSent) / Double(max(overallTotal, 1))
        return HStack(spacing: 14) {
            HaloRing(progress: progress, tint: .haloAccent, value: "\(Int(progress * 100))%", caption: nil, size: 64, lineWidth: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(HaloStrings.Share.sending) \(name)").font(HaloFont.headline).foregroundColor(.haloText).lineLimit(2)
                Text("\(Bytes.string(sent)) of \(Bytes.string(total))").font(HaloFont.caption).foregroundColor(.haloText2)
            }
            Spacer(minLength: 0)
            HaloIconButton(icon: "xmark", label: HaloStrings.Share.cancel, tint: .haloRed) { model.cancelSend() }
                .accessibilityIdentifier("share.cancel")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(progress * 100)) percent")
    }

    private func resultRow(_ message: String, state: HaloState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol).foregroundColor(state.color).accessibilityHidden(true)
            Text(message).font(HaloFont.bodyMedium).foregroundColor(.haloText).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.result")
    }

    // MARK: Received (compact)

    private var received: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloSectionHeader(HaloStrings.Share.received,
                              actionLabel: model.inbox.isEmpty ? nil : "\(HaloStrings.Share.seeAll) (\(model.inbox.count))",
                              action: { router.showInbox = true })
            HaloCard(padding: 0) {
                if model.inbox.isEmpty {
                    HaloListRow(icon: "tray", tint: .haloText3, title: HaloStrings.Share.nothingReceived)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.inbox.prefix(3).enumerated()), id: \.element.id) { i, item in
                            if i > 0 { HaloRowDivider() }
                            InboxRow(item: item)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Device tile

struct DeviceTile: View {
    let peer: Peer
    let isSelected: Bool
    let action: () -> Void

    static func icon(for peer: Peer) -> String {
        switch peer.info.deviceType {
        case "desktop": return "desktopcomputer"
        case "mobile": return "iphone"
        case "web": return "globe"
        case "headless", "server": return "server.rack"
        default: return "questionmark.circle"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: Self.icon(for: peer))
                        .font(.system(.title3).weight(.medium))
                        .foregroundColor(isSelected ? .white : .haloAccent)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(isSelected ? AnyShapeStyle(LinearGradient(colors: [.haloAccent, .haloAccent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                             : AnyShapeStyle(Color.haloAccent.opacity(0.14))))
                    Spacer()
                    if isSelected { Image(systemName: "checkmark.circle.fill").foregroundColor(.haloAccent) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.alias).font(HaloFont.headline).foregroundColor(.haloText).lineLimit(2)
                    Text(peer.info.deviceModel ?? peer.info.deviceType ?? "device")
                        .font(HaloFont.caption).foregroundColor(.haloText2).lineLimit(1)
                    Text(peer.host).font(HaloFont.mono).foregroundColor(.haloText3).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background(isSelected ? Color.haloAccent.opacity(0.12) : Color.haloSurface2)
            .clipShape(RoundedRectangle(cornerRadius: HaloLayout.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HaloLayout.cardRadius, style: .continuous)
                .stroke(isSelected ? Color.haloAccent.opacity(0.6) : Color.haloBorder, lineWidth: isSelected ? 1.5 : 1))
        }
        .buttonStyle(HaloPressStyle())
        .accessibilityLabel("\(peer.alias), \(peer.info.deviceModel ?? peer.info.deviceType ?? "device")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AddTile: View {
    let action: () -> Void
    var body: some View {
        Button { HaloHaptics.tap(); action() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(.title3).weight(.medium)).foregroundColor(.haloText2)
                Text(HaloStrings.Share.addByAddress).font(HaloFont.caption.weight(.semibold)).foregroundColor(.haloText2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .overlay(RoundedRectangle(cornerRadius: HaloLayout.cardRadius, style: .continuous)
                .strokeBorder(Color.haloBorder2, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(HaloPressStyle())
        .accessibilityLabel(HaloStrings.Share.addByAddress)
    }
}

// MARK: - Add by address (MR-DI-2)

struct AddAddressSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("For networks that block discovery.").font(HaloFont.body).foregroundColor(.haloText2)
                HStack(spacing: 8) {
                    TextField(HaloStrings.Share.addressPlaceholder, text: $model.manualAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .font(HaloFont.mono)
                        .padding(12)
                        .frame(minHeight: HaloLayout.minTarget)
                        .background(RoundedRectangle(cornerRadius: HaloLayout.controlRadius, style: .continuous).fill(Color.haloSurface2))
                        .overlay(RoundedRectangle(cornerRadius: HaloLayout.controlRadius, style: .continuous).stroke(Color.haloBorder2, lineWidth: 1))
                        .accessibilityIdentifier("share.address")
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { model.addManualPeer(); focused = false }
                }
                HaloPrimaryButton(HaloStrings.Share.addAction, icon: "plus") { model.addManualPeer(); focused = false }
                    .disabled(model.manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("share.addAddress")
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.circle.fill").font(HaloFont.caption).foregroundColor(.haloAmber)
                        .accessibilityIdentifier("share.notice")
                }
                Spacer(minLength: 0)
            }
            .padding(HaloLayout.screenPadding)
            .haloScreen()
            .navigationTitle(HaloStrings.Share.addByAddress)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(HaloStrings.Share.cancel) { dismiss() } } }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

// MARK: - Info content (moved out of the main surface)

enum ShareInfo {
    static let receiving: [HaloInfoPoint] = [
        HaloInfoPoint("hand.raised.fill", .haloGreen, "You decide", "Nothing is saved until you accept. Files never overwrite each other."),
        HaloInfoPoint("app.badge", .haloAmber, "Keep Halo open", "iPhone can't listen in the background, so Halo receives only while it is open."),
        HaloInfoPoint("wifi.exclamationmark", .haloAmber, "Not encrypted in transit", "Transfers stay on your Wi-Fi but are sent as plain HTTP. Only accept files from people you trust."),
        HaloInfoPoint("folder.fill", .haloAccent, "Where files go", "Received files are saved to Halo → Received, visible in the Files app."),
    ]
    static let discovery: [HaloInfoPoint] = [
        HaloInfoPoint("dot.radiowaves.left.and.right", .haloGreen, "Scan", "Halo checks your Wi-Fi network for devices running HaloShare or LocalSend."),
        HaloInfoPoint("iphone.gen3.radiowaves.left.and.right", .haloAmber, "Found by scanning", "iOS blocks the broadcast other devices use, so this iPhone is found only when another device scans for it."),
        HaloInfoPoint("number", .haloAccent, "Add by address", "If your network blocks discovery, type the address shown on the other device."),
    ]
}
