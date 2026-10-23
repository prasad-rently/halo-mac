import SwiftUI
import UniformTypeIdentifiers
import HaloShareKit

struct ShareView: View {
    @EnvironmentObject var model: AppModel
    @State private var picking = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    thisDevice
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
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty { model.send(urls) }
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
                    Button { model.selectedPeerID = peer.id } label: { peerRow(peer) }
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

    private func peerRow(_ peer: Peer) -> some View {
        let selected = model.selectedPeerID == peer.id
        return HStack(spacing: 12) {
            Image(systemName: icon(for: peer)).foregroundColor(selected ? .haloAccent : .haloText2).frame(width: 26)
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

    private func icon(for peer: Peer) -> String {
        switch peer.info.deviceType {
        case "desktop": return "desktopcomputer"
        case "mobile": return "iphone"
        case "web": return "globe"
        case "headless", "server": return "server.rack"
        default: return "questionmark.circle"
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
            Text("For networks that block discovery. Use the address shown on the other device.")
                .font(.system(size: 11)).foregroundColor(.haloText3).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Send / transfer

    private var transferCard: some View {
        VStack(spacing: 8) {
            SectionLabel("Send")
            HaloCard {
                VStack(alignment: .leading, spacing: 12) {
                    switch model.transfer {
                    case .idle:
                        Text(model.selectedPeer.map { "To \($0.alias)" } ?? "Choose a device above")
                            .font(.system(size: 13)).foregroundColor(.haloText2)
                    case .sending(let name, let sent, let total, let overallSent, let overallTotal):
                        Text("Sending \(name)").font(.system(size: 13, weight: .medium)).foregroundColor(.haloText)
                        ProgressView(value: Double(overallSent), total: Double(max(overallTotal, 1)))
                            .tint(.haloAccent)
                        Text("\(Bytes.string(sent)) of \(Bytes.string(total))")
                            .font(.system(size: 11)).foregroundColor(.haloText3)
                    case .finished(let message):
                        Label(message, systemImage: "checkmark.circle").font(.system(size: 13)).foregroundColor(.haloGreen)
                            .accessibilityIdentifier("share.result")
                    case .failed(let why):
                        Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundColor(.haloRed)
                            .accessibilityIdentifier("share.result")
                    }

                    HStack(spacing: 10) {
                        if model.transfer.isBusy {
                            Button(role: .destructive) { model.cancelSend() } label: { Label("Cancel", systemImage: "xmark") }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("share.cancel")
                        } else {
                            Button { model.dismissTransferResult(); picking = true } label: {
                                Label("Choose files…", systemImage: "doc.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedPeer == nil)
                            .accessibilityIdentifier("share.chooseFiles")

                            #if DEBUG
                            Button { model.dismissTransferResult(); model.sendTestFile() } label: { Text("Send 5 MB test") }
                                .buttonStyle(.bordered)
                                .disabled(model.selectedPeer == nil)
                                .accessibilityIdentifier("share.sendTest")
                            #endif
                        }
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
