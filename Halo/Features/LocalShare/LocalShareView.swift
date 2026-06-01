import SwiftUI

struct LocalShareView: View {
    @StateObject private var manager = LocalShareManager.shared
    @State private var showFilePicker = false
    @State private var selectedDevice: ShareDevice?
    @State private var dragOver = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                if let error = manager.errorMessage {
                    errorBanner(error)
                }
                if !manager.activeSessions.isEmpty {
                    activeTransfersSection
                }
                deviceSection
                historySection
            }
            .padding(24)
        }
        .background(Color.haloSurface)
        .sheet(item: $manager.pendingConsent) { _ in
            ReceiveConsentView()
                .environmentObject(manager)
        }
        .task {
            await manager.start()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HaloShare")
                    .font(HaloFont.display(24, weight: .bold))
                    .foregroundColor(.haloText)
                Text("Send & receive files with nearby devices")
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText2)
            }
            Spacer()
            statusIndicator
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(manager.isRunning ? Color.haloGreen : Color.haloRed)
                .frame(width: 8, height: 8)
            Text(manager.isRunning ? "Active" : "Offline")
                .font(HaloFont.body(12))
                .foregroundColor(.haloText2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.haloSurface2)
        .cornerRadius(20)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.haloAmber)
            Text(message)
                .font(HaloFont.body(12))
                .foregroundColor(.haloText)
            Spacer()
            Button("Dismiss") { manager.errorMessage = nil }
                .font(HaloFont.body(11))
                .foregroundColor(.haloAccent)
        }
        .padding(12)
        .background(Color.haloAmber.opacity(0.1))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloAmber.opacity(0.3)))
    }

    // MARK: - Active Transfers

    private var activeTransfersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Transfers")
                .font(HaloFont.body(14, weight: .semibold))
                .foregroundColor(.haloText)

            ForEach(manager.activeSessions) { session in
                TransferProgressRow(session: session)
            }
        }
        .padding(16)
        .background(Color.haloSurface2)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloBorder))
    }

    // MARK: - Device Section

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nearby Devices")
                    .font(HaloFont.body(14, weight: .semibold))
                    .foregroundColor(.haloText)
                Spacer()
                Button {
                    Task { await manager.refreshDevices() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloAccent)
                }
                .buttonStyle(.plain)
            }

            if manager.discoveredDevices.isEmpty {
                emptyDevicesView
            } else {
                deviceGrid
            }
        }
        .padding(16)
        .background(Color.haloSurface2)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloBorder))
    }

    private var emptyDevicesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 32))
                .foregroundColor(.haloText3)
            Text("Searching for nearby devices...")
                .font(HaloFont.body(13))
                .foregroundColor(.haloText2)
            Text("Make sure other devices have LocalSend or HaloShare running on the same network")
                .font(HaloFont.body(11))
                .foregroundColor(.haloText3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var deviceGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(manager.discoveredDevices) { device in
                DeviceCard(device: device) {
                    selectedDevice = device
                    showFilePicker = true
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            guard let device = selectedDevice,
                  let urls = try? result.get() else { return }
            Task {
                try? await manager.send(urls: urls, to: device)
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transfer History")
                    .font(HaloFont.body(14, weight: .semibold))
                    .foregroundColor(.haloText)
                Spacer()
                if !manager.transferHistory.isEmpty {
                    Text("\(manager.transferHistory.count) transfers")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText3)
                }
            }

            if manager.transferHistory.isEmpty {
                Text("No transfers yet")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(manager.transferHistory.prefix(10)) { record in
                    TransferHistoryRow(record: record)
                }
            }
        }
        .padding(16)
        .background(Color.haloSurface2)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloBorder))
    }
}

// MARK: - Device Card

struct DeviceCard: View {
    let device: ShareDevice
    let onSend: () -> Void

    var body: some View {
        Button(action: onSend) {
            VStack(spacing: 10) {
                Image(systemName: deviceIcon)
                    .font(.system(size: 28))
                    .foregroundColor(.haloAccent)
                Text(device.alias)
                    .font(HaloFont.body(13, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                if let model = device.deviceModel {
                    Text(model)
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                        .lineLimit(1)
                }
                Text("Tap to send")
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloAccent.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color.haloBackground)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder))
        }
        .buttonStyle(.plain)
    }

    private var deviceIcon: String {
        switch device.deviceType {
        case .mobile: return "iphone"
        case .desktop: return "desktopcomputer"
        case .web: return "globe"
        case .server: return "server.rack"
        default: return "laptopcomputer"
        }
    }
}

// MARK: - Transfer Progress Row

struct TransferProgressRow: View {
    let session: ShareSession

    private var totalBytes: Int64 { session.files.reduce(0) { $0 + $1.size } }
    private var transferredBytes: Int64 { session.files.reduce(0) { $0 + $1.bytesTransferred } }
    private var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: session.direction == .sending ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(session.direction == .sending ? .haloAccent : .haloGreen)
                Text(session.peer.alias)
                    .font(HaloFont.body(13, weight: .medium))
                    .foregroundColor(.haloText)
                Spacer()
                Text(stateLabel)
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText3)
            }

            if case .active = session.state {
                ProgressView(value: progress)
                    .tint(.haloAccent)
                HStack {
                    Text("\(session.files.filter { $0.status == .completed }.count)/\(session.files.count) files")
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: transferredBytes, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                        .font(HaloFont.body(10))
                        .foregroundColor(.haloText3)
                }
            }
        }
        .padding(12)
        .background(Color.haloBackground)
        .cornerRadius(10)
    }

    private var stateLabel: String {
        switch session.state {
        case .waitingForConsent: return "Waiting..."
        case .active(let done, let total): return "\(Int(progress * 100))%"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .failed(let msg): return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Transfer History Row

struct TransferHistoryRow: View {
    let record: TransferRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.direction == .sending ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundColor(record.direction == .sending ? .haloAccent : .haloGreen)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.peerAlias)
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(.haloText)
                Text("\(record.fileCount) file(s) · \(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file))")
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.date, style: .relative)
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                statusBadge
            }
        }
        .padding(.vertical, 6)
    }

    private var statusBadge: some View {
        Text(record.status.rawValue.capitalized)
            .font(HaloFont.body(9, weight: .medium))
            .foregroundColor(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .cornerRadius(4)
    }

    private var statusColor: Color {
        switch record.status {
        case .completed: return .haloGreen
        case .failed: return .haloRed
        case .cancelled: return .haloAmber
        }
    }
}
