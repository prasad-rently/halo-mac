// ──────────────────────────────────────────────────────────────────────────────
// LetheSheets.swift — F-052
//
// Create / join / invite sheets, plus the privacy panel.
//
// The QR code is rendered with CoreImage's built-in generator rather than a
// dependency. There is deliberately no QR *scanner* in v1 — see the note on
// `LetheInviteSheet`.
// ──────────────────────────────────────────────────────────────────────────────

import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

// MARK: - Create

struct LetheCreateRoomSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New room").font(HaloFont.display(17, weight: .bold)).foregroundColor(.haloText)
            Text("The name stays on your devices — it is encrypted inside the invite link "
                 + "and never reaches the relay.")
                .font(.caption).foregroundColor(.haloText3)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Room name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Color.haloSurface)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

// MARK: - Join

struct LetheJoinRoomSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?
    /// Returns an error string, or nil on success.
    let onJoin: (String) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join a room").font(HaloFont.display(17, weight: .bold)).foregroundColor(.haloText)
            Text("Paste a `lethe://join#…` invite. The key is inside the link's fragment, "
                 + "which is never sent to any server.")
                .font(.caption).foregroundColor(.haloText3)
                .fixedSize(horizontal: false, vertical: true)

            TextField("lethe://join#roomId=…", text: $link, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .font(HaloFont.mono(10))

            Button {
                if let s = NSPasteboard.general.string(forType: .string) { link = s }
            } label: { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                .buttonStyle(.link)

            if let error {
                Text(error).font(.caption).foregroundColor(.haloRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Join") { join() }
                    .buttonStyle(.borderedProminent)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color.haloSurface)
    }

    private func join() {
        if let err = onJoin(link.trimmingCharacters(in: .whitespacesAndNewlines)) {
            error = err
        } else {
            dismiss()
        }
    }
}

// MARK: - Invite

struct LetheInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let room: LetheRoom
    let link: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Invite to “\(room.name)”")
                .font(HaloFont.display(17, weight: .bold)).foregroundColor(.haloText)

            if let link {
                if let image = Self.qrImage(for: link) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .background(Color.white)
                        .cornerRadius(8)
                }

                Text(link)
                    .font(HaloFont.mono(9)).foregroundColor(.haloText3)
                    .textSelection(.enabled)
                    .lineLimit(3).truncationMode(.middle)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.haloSurface2))

                Text("Anyone with this link can read the room, now and in future. "
                     + "There is no way to remove a member — make a new room instead.")
                    .font(.caption).foregroundColor(.haloAmber)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy link",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        let picker = NSSharingServicePicker(items: [link])
                        if let window = NSApp.keyWindow, let view = window.contentView {
                            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
                        }
                    } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
            } else {
                Text("The key for this room is no longer on this Mac, so an invite "
                     + "cannot be rebuilt.")
                    .font(.callout).foregroundColor(.haloRed)
                    .multilineTextAlignment(.center)
            }

            Button("Done") { dismiss() }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.haloSurface)
    }

    /// CoreImage's generator — no dependency needed. `.none` interpolation on
    /// the Image keeps the modules crisp when scaled up.
    static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width,
                                                 height: scaled.extent.height))
    }
}

// MARK: - Privacy panel (FR-L-30)

struct LethePrivacyPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What the relay can see").font(.headline).foregroundColor(.haloText)

            Group {
                row("✓", "That a connection was made, and your IP address", .haloAmber)
                row("✓", "An opaque room id — 16 hex characters, meaningless without the key", .haloText2)
                row("✓", "Encrypted blobs, with the time they arrived", .haloText2)
                row("✕", "Message text", .haloGreen)
                row("✕", "Who sent what", .haloGreen)
                row("✕", "The room name or the room key", .haloGreen)
            }

            Divider().overlay(Color.haloSurface2)

            Text("""
                 Messages are encrypted on this Mac with AES-256-GCM before they leave it, \
                 and the key never goes to the relay. The relay keeps the last 50 messages \
                 for up to 6 hours so someone joining late can catch up, then forgets them.

                 Your IP is visible to the relay — that is unavoidable at the transport layer. \
                 A VPN is the answer if that matters to you.

                 Halo includes Sentry crash reporting. It is off unless you turn it on, and \
                 nothing from this module — no room id, key, handle, invite link or message \
                 text — is ever attached to a crash report either way.
                 """)
                .font(.caption).foregroundColor(.haloText3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.haloSurface))
    }

    private func row(_ mark: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(mark).font(.caption.weight(.bold)).foregroundColor(color).frame(width: 12)
            Text(text).font(.caption).foregroundColor(.haloText2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

// MARK: - Settings (FR-L-03, FR-L-30, FR-L-32)
//
// Handle editing, relay selection and the privacy panel were all implemented in
// `LetheManager` / `LethePrivacyPanel` before this existed — and were
// unreachable, which meant three spec requirements were unmet despite the code
// being written. This is the surface that makes them real.

struct LetheSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: LetheManager

    @State private var handleDraft = ""
    @State private var relayDraft = ""
    @State private var relayError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Lethe settings")
                    .font(HaloFont.display(17, weight: .bold)).foregroundColor(.haloText)

                // Handle — FR-L-03
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your handle").font(.subheadline.weight(.semibold)).foregroundColor(.haloText)
                    Text("Shown to others in the room. It is inside the encrypted payload — "
                         + "the relay never sees it. Anyone can pick any handle; there is no "
                         + "identity system, so a handle proves nothing.")
                        .font(.caption).foregroundColor(.haloText3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("handle", text: $handleDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(HaloFont.mono(11))
                        Button("Randomise") { handleDraft = LetheCrypto.generateHandle() }
                        Button("Save") { manager.setHandle(handleDraft) }
                            .buttonStyle(.borderedProminent)
                            .disabled(handleDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                      || handleDraft == manager.handle)
                    }
                }

                Divider().overlay(Color.haloSurface2)

                // Relay — FR-L-32
                VStack(alignment: .leading, spacing: 6) {
                    Text("Relay").font(.subheadline.weight(.semibold)).foregroundColor(.haloText)
                    Text("The relay is open source and self-hostable. \"You can verify it stores "
                         + "nothing\" only means something if you can point Halo at your own.")
                        .font(.caption).foregroundColor(.haloText3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("wss://…", text: $relayDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(HaloFont.mono(10))
                        Button("Reset") { relayDraft = LetheLimits.defaultRelayURL }
                        Button("Apply") { applyRelay() }
                            .buttonStyle(.borderedProminent)
                            .disabled(relayDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                      || relayDraft == manager.relayURLString)
                    }
                    if let relayError {
                        Text(relayError).font(.caption).foregroundColor(.haloRed)
                    }
                    Text("Changing this reconnects. Rooms are unaffected — a room lives in its "
                         + "key, not in a server.")
                        .font(.caption2).foregroundColor(.haloText3)
                }

                Divider().overlay(Color.haloSurface2)

                // FR-L-30
                LethePrivacyPanel()

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 620)
        .background(Color.haloSurface)
        .onAppear {
            handleDraft = manager.handle
            relayDraft = manager.relayURLString
        }
    }

    private func applyRelay() {
        let trimmed = relayDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss", url.host != nil else {
            relayError = "Needs to be a ws:// or wss:// URL with a host."
            return
        }
        relayError = nil
        manager.setRelayURL(trimmed)
    }
}
