import SwiftUI

// MARK: - ClipboardSyncSettingsView  (F-045)
//
// The clipboard-sync control surface: reuses the shared F-044 cloud config, adds
// the sync on/off toggle, the opt-in sensitive filter (D5), and the prominent
// purge control (D10). If the cloud isn't set up yet, points the user to the
// Messages module where the shared Firebase is configured.

struct ClipboardSyncSettingsView: View {
    @ObservedObject var sync: ClipboardSyncService
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var confirmPurge = false
    @State private var busy = false

    private var connected: Bool { if case .connected = sync.state { return true }; return false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusBanner
                if !sync.isConfigured {
                    notConfiguredNote
                } else {
                    enableSection
                    if sync.syncEnabled { filterSection; purgeSection }
                }
                doneRow
            }
            .padding(24)
            .frame(width: 480)
            .disabled(busy)
        }
        .background(Color.haloSurface)
        .confirmationDialog("Purge synced clipboard items?", isPresented: $confirmPurge) {
            Button("Purge", role: .destructive) { run { await sync.purge() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every synced item from your cloud and from this Mac's history. Locally-copied items are kept.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Clipboard sync").font(HaloFont.display(20)).foregroundColor(.haloText)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            Text("Copy on one device, paste on another. Items are end-to-end encrypted with your shared key before upload — your Firebase only ever stores ciphertext. This Mac: **\(sync.deviceName)**.")
                .font(HaloFont.body(12)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusBanner: some View {
        switch sync.state {
        case .connecting: banner("Connecting…", .haloAmber, "arrow.triangle.2.circlepath")
        case .connected:  banner("Sync active", .haloGreen, "checkmark.seal.fill")
        case .error(let m): banner(m, .haloRed, "exclamationmark.triangle.fill")
        case .unconfigured: EmptyView()
        }
    }

    private func banner(_ text: String, _ color: Color, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).font(HaloFont.body(12)).foregroundColor(.haloText)
            Spacer()
        }
        .padding(10).background(color.opacity(0.12)).cornerRadius(8)
    }

    private var notConfiguredNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.icloud").foregroundColor(.haloAccent)
            Text("Connect your Firebase first in the **Messages** module. Clipboard sync reuses the same account and encryption key.")
                .font(HaloFont.body(12)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12).background(Color.haloSurface2).cornerRadius(10)
    }

    private var enableSection: some View {
        section("Sync", "") {
            Toggle(isOn: Binding(get: { sync.syncEnabled }, set: { toggleEnabled($0) })) {
                Text("Enable clipboard sync").font(HaloFont.body(12)).foregroundColor(.haloText)
            }
            .toggleStyle(.switch).tint(.haloAccent)

            // Needs the E2E passphrase to derive the shared key (unless cached).
            if sync.syncEnabled && !connected {
                Text("Enter your encryption passphrase to start syncing on this Mac.")
                    .font(HaloFont.body(11)).foregroundColor(.haloText2)
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
                    .padding(8).background(Color.haloSurface2).cornerRadius(7)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.haloBorder, lineWidth: 1))
                HaloPrimaryButton("Connect", icon: "link") { connect() }
                    .disabled(passphrase.isEmpty)
            }
        }
    }

    private var filterSection: some View {
        section("Privacy", "Nothing is excluded by default. Turn this on to skip likely secrets (passwords, API keys, tokens) — they won't leave this Mac.") {
            Toggle(isOn: $sync.filterSensitive) {
                Text("Don't sync likely secrets").font(HaloFont.body(12)).foregroundColor(.haloText)
            }
            .toggleStyle(.switch).tint(.haloAccent)
        }
    }

    private var purgeSection: some View {
        section("Purge", "Instantly remove all synced items from the cloud and this Mac.") {
            HaloGhostButton("Purge synced items", icon: "trash") { confirmPurge = true }
        }
    }

    private var doneRow: some View {
        HStack { Spacer(); HaloPrimaryButton("Done", icon: "checkmark") { dismiss() } }
    }

    // MARK: Actions

    private func toggleEnabled(_ on: Bool) {
        sync.setEnabled(on)
        if on {
            // Auto-connect if the passphrase is already cached from a prior session.
            if !connected, let cached = CloudConfigStore.shared.cachedPassphrase {
                run { await sync.connect(passphrase: cached) }
            }
        }
    }

    private func connect() {
        let pass = passphrase
        run {
            await sync.connect(passphrase: pass)
            // Cache for convenience so sync resumes on next launch (device-local).
            if case .connected = sync.state { CloudConfigStore.shared.cachedPassphrase = pass }
        }
        passphrase = ""
    }

    private func run(_ op: @escaping () async -> Void) {
        busy = true
        Task { await op(); busy = false }
    }

    private func section<C: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
            if !subtitle.isEmpty {
                Text(.init(subtitle)).font(HaloFont.body(11)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(14)
        .background(Color.haloSurface2.opacity(0.5)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
    }
}
