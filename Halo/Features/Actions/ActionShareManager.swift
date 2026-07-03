import Foundation
import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

// MARK: - ActionShareManager

/// Handles encoding, decoding, sharing, and importing actions via `halo://` deep links.
@MainActor
final class ActionShareManager: ObservableObject {

    static let shared = ActionShareManager()

    @Published var pendingImport: ActionImportPayload?
    @Published var showImportSheet = false
    @Published var statusMessage: String?

    private init() {}

    // MARK: - URL Scheme

    /// Handle an incoming `halo://` URL.
    func handleURL(_ url: URL) {
        guard url.scheme == "halo" else { return }

        switch url.host {
        case "action":
            // Single action: halo://action/{base64}
            guard let encoded = url.pathComponents.dropFirst().first,
                  let data = Data(base64Encoded: encoded
                      .replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")) else {
                statusMessage = "Invalid action link"
                return
            }
            guard let action = try? JSONDecoder().decode(ActionItem.self, from: data) else {
                statusMessage = "Could not decode action"
                return
            }
            pendingImport = ActionImportPayload(actions: [action], source: .deepLink)
            showImportSheet = true

        case "actions":
            // Batch: halo://actions/{base64}
            guard let encoded = url.pathComponents.dropFirst().first,
                  let data = Data(base64Encoded: encoded
                      .replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")) else {
                statusMessage = "Invalid actions link"
                return
            }
            guard let actions = try? JSONDecoder().decode([ActionItem].self, from: data) else {
                statusMessage = "Could not decode actions"
                return
            }
            pendingImport = ActionImportPayload(actions: actions, source: .deepLink)
            showImportSheet = true

        default:
            break
        }
    }

    // MARK: - Encoding

    /// Generate a `halo://action/...` URL for a single action.
    func shareURL(for action: ActionItem) -> URL? {
        // Strip runtime state before encoding
        var clean = action
        clean.usageCount = 0
        clean.lastUsed = nil
        clean.isPinned = false
        clean.isBuiltIn = false

        guard let data = try? JSONEncoder().encode(clean) else { return nil }
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "halo://action/\(base64)")
    }

    /// Generate a `halo://actions/...` URL for multiple actions.
    func shareURL(for actions: [ActionItem]) -> URL? {
        var cleaned = actions.map { a -> ActionItem in
            var c = a; c.usageCount = 0; c.lastUsed = nil; c.isPinned = false; c.isBuiltIn = false
            return c
        }
        _ = cleaned  // suppress warning
        guard let data = try? JSONEncoder().encode(cleaned) else { return nil }
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "halo://actions/\(base64)")
    }

    // MARK: - Share actions

    func copyLink(for action: ActionItem) {
        guard let url = shareURL(for: action) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        statusMessage = "Link copied to clipboard"
        clearStatusAfterDelay()
    }

    func showShareSheet(for action: ActionItem, from view: NSView? = nil) {
        guard let url = shareURL(for: action) else { return }
        let items: [Any] = [url.absoluteString]
        let picker = NSSharingServicePicker(items: items)
        if let v = view ?? NSApp.keyWindow?.contentView {
            picker.show(relativeTo: .zero, of: v, preferredEdge: .minY)
        }
    }

    /// Generate a QR code image from the action's share URL.
    func generateQRCode(for action: ActionItem) -> NSImage? {
        guard let url = shareURL(for: action) else { return nil }
        let data = url.absoluteString.data(using: .utf8)

        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up from tiny QR to usable size
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: scale)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - JSON File Import / Export

    func exportAllCustomActions() {
        let customs = ActionLibrary.shared.actions.filter { !$0.isBuiltIn }
        guard !customs.isEmpty else {
            statusMessage = "No custom actions to export"
            clearStatusAfterDelay()
            return
        }
        guard let data = try? JSONEncoder().encode(customs) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "halo-actions.json"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? data.write(to: url)
                Task { @MainActor in
                    self.statusMessage = "Exported \(customs.count) custom actions"
                    self.clearStatusAfterDelay()
                }
            }
        }
    }

    func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url),
                  let actions = try? JSONDecoder().decode([ActionItem].self, from: data) else { return }
            Task { @MainActor in
                self.pendingImport = ActionImportPayload(actions: actions, source: .file)
                self.showImportSheet = true
            }
        }
    }

    // MARK: - Import confirmation

    func confirmImport() {
        guard let payload = pendingImport else { return }
        for var action in payload.actions {
            action.id = UUID()  // new ID to avoid collisions
            action.isBuiltIn = false
            action.usageCount = 0
            action.lastUsed = nil
            ActionLibrary.shared.add(custom: action)
        }
        statusMessage = "Imported \(payload.actions.count) action\(payload.actions.count == 1 ? "" : "s")"
        clearStatusAfterDelay()
        pendingImport = nil
        showImportSheet = false
    }

    func cancelImport() {
        pendingImport = nil
        showImportSheet = false
    }

    // MARK: - Private

    private func clearStatusAfterDelay() {
        let msg = statusMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.statusMessage == msg { self?.statusMessage = nil }
        }
    }
}

// MARK: - Import Payload

struct ActionImportPayload {
    let actions: [ActionItem]
    let source: ImportSource

    enum ImportSource {
        case deepLink
        case file
    }
}

// MARK: - Action Import Sheet

struct ActionImportSheet: View {
    @ObservedObject var shareManager: ActionShareManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.haloAccent)
                Text("Import Actions")
                    .font(HaloFont.display(16, weight: .bold))
                    .foregroundColor(.haloText)
                Spacer()
            }
            .padding(20)

            Divider().background(Color.haloBorder)

            if let payload = shareManager.pendingImport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The following \(payload.actions.count) action\(payload.actions.count == 1 ? "" : "s") will be added to your custom actions:")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                            .padding(.bottom, 4)

                        ForEach(payload.actions) { action in
                            ImportActionRow(action: action)
                        }
                    }
                    .padding(20)
                }

                Divider().background(Color.haloBorder)

                // Action buttons
                HStack {
                    Button("Cancel") {
                        shareManager.cancelImport()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.haloText2)

                    Spacer()

                    Button("Import \(payload.actions.count) Action\(payload.actions.count == 1 ? "" : "s")") {
                        shareManager.confirmImport()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: CGFloat(min(400, 180 + (shareManager.pendingImport?.actions.count ?? 0) * 80)))
        .background(Color.haloSurface)
    }
}

private struct ImportActionRow: View {
    let action: ActionItem

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    // Icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(action.iconColor.opacity(0.15))
                            .frame(width: 32, height: 32)
                        Image(systemName: action.icon)
                            .font(.system(size: 14))
                            .foregroundColor(action.iconColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.name)
                            .font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.haloText)
                        Text(action.subtitle)
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                            .lineLimit(2)
                    }

                    Spacer()

                    // Category badge
                    Text(action.category.rawValue)
                        .font(HaloFont.body(10, weight: .medium))
                        .foregroundColor(action.category.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(action.category.color.opacity(0.1))
                        .cornerRadius(5)
                }

                // Privilege warning
                if action.requiresPrivilege {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.haloAmber)
                        Text("Requires administrator privileges")
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloAmber)
                    }
                    .padding(6)
                    .background(Color.haloAmber.opacity(0.08))
                    .cornerRadius(6)
                }

                // Script preview (first 3 lines)
                if case .shell(let script) = action.command {
                    let preview = script.components(separatedBy: "\n").prefix(3).joined(separator: "\n")
                    Text(preview)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.haloText3)
                        .lineLimit(3)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.haloBackground)
                        .cornerRadius(6)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - QR Code Sheet

struct ActionQRCodeSheet: View {
    let action: ActionItem
    let qrImage: NSImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Share Action")
                .font(HaloFont.display(16, weight: .bold))
                .foregroundColor(.haloText)

            // QR Code
            Image(nsImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .cornerRadius(8)
                .background(Color.white)
                .cornerRadius(12)

            Text(action.name)
                .font(HaloFont.body(14, weight: .semibold))
                .foregroundColor(.haloText)

            Text("Scan this QR code on another Mac running Halo to import this action.")
                .font(HaloFont.body(11))
                .foregroundColor(.haloText3)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.haloText2)

                Button("Copy Link") {
                    ActionShareManager.shared.copyLink(for: action)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 300)
        .background(Color.haloSurface)
    }
}
