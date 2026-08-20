import Foundation
import AppKit

// MARK: - DriveMonitor  (F-051)
//
// Observes NSWorkspace mount/unmount notifications and resolves each
// volume's stable identity (see `DriveVolume.driveKey`). No prior art for
// this in the codebase — mirrors IdleAppMonitor's observer-token pattern
// (actor + addObserver/removeObserver, closures hop into the actor via a
// `Task`).

enum DriveMonitorEvent: Sendable {
    case mounted(DriveVolume)
    case unmounted(driveKey: String)
}

actor DriveMonitor {

    private var observerTokens: [NSObjectProtocol] = []
    private var onEvent: (@Sendable (DriveMonitorEvent) -> Void)?
    /// driveKey → volume path, so an unmount notification (which only gives
    /// us the path) can still be resolved back to the identity it mounted as.
    private var pathToDriveKey: [String: String] = [:]

    // MARK: - Start / Stop

    func startMonitoring(onEvent: @escaping @Sendable (DriveMonitorEvent) -> Void) {
        self.onEvent = onEvent

        let mountToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { await self?.handleMount(at: url) }
        }
        observerTokens.append(mountToken)

        let unmountToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { await self?.handleUnmount(at: url) }
        }
        observerTokens.append(unmountToken)
    }

    func stopMonitoring() {
        for token in observerTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        onEvent = nil
    }

    // MARK: - Handlers

    private func handleMount(at url: URL) {
        guard let volume = DriveMonitor.resolveVolume(at: url) else { return }
        pathToDriveKey[url.path] = volume.driveKey
        onEvent?(.mounted(volume))
    }

    private func handleUnmount(at url: URL) {
        guard let driveKey = pathToDriveKey.removeValue(forKey: url.path) else { return }
        onEvent?(.unmounted(driveKey: driveKey))
    }

    // MARK: - Resolution

    /// Reads the same resource keys `DriveSpeedTester.availableVolumes()`
    /// does, for one specific volume URL (a mount notification gives us the
    /// URL directly, so no need to enumerate every mounted volume).
    nonisolated static func resolveVolume(at url: URL) -> DriveVolume? {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsBrowsableKey, .volumeIsLocalKey, .volumeUUIDStringKey
        ]
        guard let rv = try? url.resourceValues(forKeys: Set(keys)),
              rv.volumeIsLocal == true, rv.volumeIsBrowsable == true else { return nil }
        return DriveVolume(
            id: url.path,
            name: rv.volumeName ?? url.lastPathComponent,
            url: url,
            isInternal: rv.volumeIsInternal ?? true,
            isRemovable: rv.volumeIsRemovable ?? false,
            totalBytes: Int64(rv.volumeTotalCapacity ?? 0),
            freeBytes: Int64(rv.volumeAvailableCapacity ?? 0),
            volumeUUID: rv.volumeUUIDString
        )
    }
}
