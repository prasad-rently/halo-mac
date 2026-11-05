import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import HaloShareKit

struct ShareView: View {
    @EnvironmentObject var model: AppModel
    @State private var picking = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    thisDevice
                    localNetworkStatus
                    outboxCard
                    nearby
                    addByAddress
                    transferCard
                    cloudFeatures
                }
                .padding(16)
            }
            .background(Color.haloBackground)
            // The keyboard must be dismissable: it otherwise covers the Send button.
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { addressFocused = false }
                }
            }
            .navigationTitle("Halo")
            .navigationBarTitleDisplayMode(.large)
            // Picking only lines files up; the send happens from the sheet, after a device is chosen.
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.queue(pickedFiles: urls) }
            }
            .onChange(of: photoSelection) { items in
                guard !items.isEmpty else { return }
                model.queue(photos: items)
                photoSelection = []
            }
        }
    }

    // MARK: This device

    private var thisDevice: some View {
        HaloCard {
            HStack(spacing: 12) {
                Image(systemName: "iphone").font(.system(size: 22)).foregroundColor(.haloAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.identity.alias).font(.system(size: 16, weight: .semibold)).foregroundColor(.haloText)
                    HStack(spacing: 6) {
                        Circle().fill(listenColor).frame(width: 8, height: 8)
                        Text(listenText).font(.system(size: 12)).foregroundColor(.haloText2)
                    }
                }
                Spacer()
            }
        }
        .accessibilityIdentifier("share.thisDevice")
    }

    private var listenColor: Color {
        switch model.listenState {
        case .listening: return .haloGreen
        case .starting: return .haloAmber
        case .stopped, .failed: return .haloRed
        }
    }

    private var listenText: String {
        switch model.listenState {
        case .listening(let port): return "Ready to receive · port \(port)"
        case .starting: return "Starting…"
        case .stopped: return "Not listening"
        case .failed(let why): return "Can't receive: \(why)"
        }
    }

    // MARK: Nearby

    private var nearby: some View {
        VStack(spacing: 8) {
            HStack {
                SectionLabel("Nearby devices")
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.stopScan() }.font(.system(size: 12))
                } else {
                    Button { model.scan() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityIdentifier("share.scan")
                }
            }

            if model.peers.isEmpty {
                HaloCard {
                    Text(model.isScanning ? "Looking on your Wi-Fi…"
                                          : "No devices yet. Tap Scan, or add an address below.")
                        .font(.system(size: 13)).foregroundColor(.haloText3)
                }
            } else {
                ForEach(model.peers) { peer in
                    Button { model.selectedPeerID = peer.id } label: { PeerRow(peer: peer, selected: model.selectedPeerID == peer.id) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("share.peer.\(peer.alias)")
                }
            }

            if let notice = model.notice {
                Text(notice).font(.system(size: 12)).foregroundColor(.haloAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("share.notice")
            }
        }
    }

    // MARK: Manual address (MR-DI-2)

    private var addByAddress: some View {
        VStack(spacing: 8) {
            SectionLabel("Add by address")
            HStack(spacing: 8) {
                TextField("192.168.1.20 or 192.168.1.20:53317", text: $model.manualAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.haloSurface2))
                    .accessibilityIdentifier("share.address")
                    .focused($addressFocused)
                    .submitLabel(.go)
                    .onSubmit { model.addManualPeer(); addressFocused = false }
                Button("Add") { model.addManualPeer(); addressFocused = false }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("share.addAddress")
            }
            if !model.recentAddresses.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.recentAddresses, id: \.self) { address in
                            Button { model.addManualPeer(address: address) } label: {
                                Text(address).font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Color.haloSurface2))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Forget", role: .destructive) { model.forgetAddress(address) } }
                            .accessibilityIdentifier("share.recent.\(address)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Local Network (MR-SH-4 / MR-DI-5)

    @ViewBuilder private var localNetworkStatus: some View {
        if !model.localNetworkExplained { LocalNetworkExplainer() }
        else if model.localNetwork == .denied { LocalNetworkDeniedCard() }
    }

    // MARK: Outbox

    @ViewBuilder private var outboxCard: some View {
        if let outbox = model.outbox {
            Button { model.showSendSheet = true } label: {
                HaloCard {
                    HStack(spacing: 10) {
                        Image(systemName: "tray.full").foregroundColor(.haloAccent)
                        Text("\(outbox.files.count) · \(Bytes.string(outbox.totalBytes))").font(.system(size: 14, weight: .semibold)).foregroundColor(.haloText)
                        HaloChip(text: ShareStrings.notSentYet, tint: .haloAmber)
                        if model.otherStagedBatchCount > 0 { HaloChip(text: "+\(model.otherStagedBatchCount)", tint: .haloText2) }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.haloText3)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("share.reviewOutbox")
        }
    }

    // MARK: Pick

    private var transferCard: some View {
        VStack(spacing: 8) {
            SectionLabel("Send")
            HaloCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button { picking = true } label: { Label("Files", systemImage: "doc.badge.plus") }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.transfer.isBusy)
                            .accessibilityIdentifier("share.chooseFiles")

                        PhotosPicker(selection: $photoSelection, maxSelectionCount: 25, matching: .any(of: [.images, .videos])) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.transfer.isBusy)
                        .accessibilityIdentifier("share.choosePhotos")

                        #if DEBUG
                        Button { model.queueTestFile() } label: { Text("5 MB test") }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("share.sendTest")
                        #endif
                    }
                }
            }
        }
    }

    // MARK: Cloud features (MR-SH-3)

    private var cloudFeatures: some View {
        VStack(spacing: 8) {
            SectionLabel("Coming with the Halo cloud foundation")
            HaloCard {
                VStack(alignment: .leading, spacing: 10) {
                    blockedRow("message", "SMS sync", "Android only")
                    Divider().overlay(Color.haloBorder)
                    blockedRow("doc.on.clipboard", "Clipboard sync", "Phone ↔ Mac")
                    Divider().overlay(Color.haloBorder)
                    blockedRow("qrcode.viewfinder", "Pair with your Mac", "Scan a QR to connect your Firebase")
                    Text("These need the shared cloud layer (F-044) that hasn't been built yet. HaloShare doesn't — it works today.")
                        .font(.system(size: 11)).foregroundColor(.haloText3)
                }
            }
            .opacity(0.8)
        }
        .accessibilityIdentifier("share.cloudFeatures")
    }

    private func blockedRow(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundColor(.haloText3).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundColor(.haloText2)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.haloText3)
            }
            Spacer()
            Text("Not yet").font(.system(size: 10, weight: .semibold)).foregroundColor(.haloAmber)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.haloAmber.opacity(0.14)))
        }
    }
}
