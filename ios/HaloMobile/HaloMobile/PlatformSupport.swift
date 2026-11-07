import SwiftUI
import UIKit
import UserNotifications
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import HaloShareKit

// MARK: - Background task (UIKit side of BackgroundTransferGuard)

/// `UIApplication.beginBackgroundTask` for the guard. The system gives a short grace period
/// (historically ~30 s) — enough to finish a transfer in flight, never to host a listener.
@MainActor
final class UIKitBackgroundTasks: BackgroundTaskProviding {
    private var identifiers: [Int: UIBackgroundTaskIdentifier] = [:]
    private var next = 0

    func beginTask(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        next += 1
        let token = next
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // UIKit calls this on the main thread.
            MainActor.assumeIsolated {
                expiration()
                self?.endTask(token)
            }
        }
        guard id != .invalid else { return nil }
        identifiers[token] = id
        return token
    }

    func endTask(_ token: Int) {
        guard let id = identifiers.removeValue(forKey: token) else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}

// MARK: - Local notification: "tap to finish"

/// Posted only when a transfer could not complete before iOS suspended the app. The text is
/// fixed and generic — never a file name, a device name or any content (notification text is
/// rendered by the OS and can be mirrored or shown on a lock screen).
@MainActor
final class InterruptionNotifier: InterruptionNotifying {
    static let identifier = "halo.share.interrupted"

    /// Asked once, when the first transfer starts — the one moment the reason is obvious.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    func notifyInterrupted(_ work: Set<BackgroundTransferGuard.Work>) {
        let content = UNMutableNotificationContent()
        content.title = "HaloShare paused"
        content.body = work.contains(.sending)
            ? "A transfer couldn't finish while Halo was in the background. Tap to reopen Halo and send again."
            : "A transfer was interrupted while Halo was in the background. Tap to reopen Halo — the other device can send again."
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    static func clearDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

// MARK: - Photos (PhotosPicker needs no permission)

/// A picked photo/video, copied to a private temp folder — as a *file*, so a 4 GB video is
/// never loaded into memory (MR-TX-5).
struct PickedMedia: Transferable {
    let url: URL

    static let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-picks", isDirectory: true)

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMedia(url: dest)
        }
    }

    static func purgeLeftovers() { try? FileManager.default.removeItem(at: rootDirectory) }
}
