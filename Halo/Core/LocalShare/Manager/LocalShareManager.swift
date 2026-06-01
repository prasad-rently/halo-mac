import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class LocalShareManager: ObservableObject {
    static let shared = LocalShareManager()

    // MARK: - Published State

    @Published var discoveredDevices: [ShareDevice] = []
    @Published var activeSessions: [ShareSession] = []
    @Published var transferHistory: [TransferRecord] = []
    @Published var pendingConsent: IncomingTransfer?
    @Published var isRunning = false
    @Published var errorMessage: String?

    struct IncomingTransfer: Identifiable {
        var id: String { request.info.fingerprint + "_" + String(Date().timeIntervalSince1970) }
        var request: PrepareUploadRequest
        var sourceIP: String
        var continuation: CheckedContinuation<PrepareUploadResponse?, Never>?
    }

    // MARK: - Sub-systems

    private let discovery = MulticastDiscovery()
    private let server = LocalShareServer()
    private let client = LocalShareClient.shared
    private let powerAssertion = TransferPowerAssertion()
    private var deviceExpiryTimer: Timer?
    private var saveDirectory: URL

    private init() {
        saveDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        loadHistory()
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        do {
            try TLSManager.shared.loadOrCreate()
        } catch {
            errorMessage = "TLS setup failed: \(error.localizedDescription)"
            return
        }

        // Start HTTP server
        do {
            try await server.start(
                port: 53317,
                parameters: TLSManager.shared.httpParameters(),
                onPrepareUpload: { [weak self] request, ip in
                    await self?.handleIncomingPrepareUpload(request: request, sourceIP: ip)
                },
                onFileReceived: { [weak self] sessionId, fileId, url in
                    Task { @MainActor in self?.handleFileReceived(sessionId: sessionId, fileId: fileId, url: url) }
                },
                onCancel: { [weak self] sessionId in
                    Task { @MainActor in self?.handleSessionCancelled(sessionId: sessionId) }
                },
                onProgress: { [weak self] sessionId, fileId, bytes in
                    Task { @MainActor in self?.handleReceiveProgress(sessionId: sessionId, fileId: fileId, bytes: bytes) }
                }
            )
        } catch {
            errorMessage = "Server failed: \(error.localizedDescription)"
            return
        }

        // Start discovery
        do {
            try await discovery.startListening { [weak self] device, ip in
                Task { @MainActor in
                    self?.handleDiscoveredDevice(device)
                }
            }
        } catch {
            errorMessage = "Discovery failed: \(error.localizedDescription)"
        }

        // Expire stale devices every 60s
        deviceExpiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireStaleDevices() }
        }

        isRunning = true
    }

    func stop() async {
        deviceExpiryTimer?.invalidate()
        await server.stop()
        await discovery.stop()
        isRunning = false
    }

    // MARK: - Sending

    func send(urls: [URL], to device: ShareDevice) async throws {
        let files = expandURLsToShareFiles(urls)
        guard !files.isEmpty else { return }

        powerAssertion.begin(reason: "HaloShare file transfer in progress")
        defer { powerAssertion.end() }

        let response = try await client.prepareUpload(to: device, files: files)
        let sessionId = response.sessionId

        // Assign tokens to files
        var tokenedFiles = files.map { file -> ShareFile in
            let token = response.files[file.id] ?? ""
            return file.with(token: token)
        }

        let session = ShareSession(
            id: sessionId,
            direction: .sending,
            peer: device,
            files: tokenedFiles,
            state: .active(filesCompleted: 0, filesTotal: files.count),
            startedAt: Date()
        )
        activeSessions.append(session)

        // Upload all files
        var completedCount = 0
        try await client.sendAll(files: tokenedFiles, sessionId: sessionId, to: device) { [weak self] fileId, sent, total in
            Task { @MainActor in
                self?.updateSendProgress(sessionId: sessionId, fileId: fileId, bytesSent: sent, totalBytes: total)
            }
        }

        // Mark complete
        if let idx = activeSessions.firstIndex(where: { $0.id == sessionId }) {
            activeSessions[idx].state = .completed
            activeSessions[idx].completedAt = Date()

            let record = TransferRecord(
                id: sessionId,
                peerAlias: device.alias,
                peerFingerprint: device.fingerprint,
                direction: .sending,
                fileCount: files.count,
                totalBytes: files.reduce(0) { $0 + $1.size },
                date: Date(),
                status: .completed,
                fileNames: files.map(\.fileName)
            )
            transferHistory.insert(record, at: 0)
            saveHistory()

            // Remove from active after delay
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    self.activeSessions.removeAll { $0.id == sessionId }
                }
            }
        }

        postNotification(title: "Transfer Complete", body: "Sent \(files.count) file(s) to \(device.alias)")
    }

    // MARK: - Receiving (Consent)

    func acceptTransfer(destDirectory: URL? = nil) {
        guard var pending = pendingConsent else { return }
        let dest = destDirectory ?? saveDirectory
        self.saveDirectory = dest

        let sessionId = UUID().uuidString
        var tokens: [String: String] = [:]
        var fileMap: [String: ShareFile] = [:]

        for (fileId, fileDTO) in pending.request.files {
            let token = UUID().uuidString
            tokens[fileId] = token
            fileMap[fileId] = ShareFile(
                id: fileId,
                fileName: fileDTO.fileName,
                size: fileDTO.size,
                fileType: fileDTO.fileType,
                sha256: fileDTO.sha256,
                preview: fileDTO.preview,
                metadata: fileDTO.metadata,
                token: token
            )
        }

        let response = PrepareUploadResponse(sessionId: sessionId, files: tokens)

        // Register session on server
        Task {
            await server.registerSession(id: sessionId, tokens: tokens, files: fileMap, destDirectory: dest)
        }

        // Create active session
        let peerInfo = pending.request.info
        let peer = ShareDevice(
            alias: peerInfo.alias,
            version: peerInfo.version,
            deviceModel: peerInfo.deviceModel,
            deviceType: peerInfo.deviceType.flatMap { DeviceType(rawValue: $0) },
            fingerprint: peerInfo.fingerprint,
            port: peerInfo.port,
            protocol_: TransportProtocol(rawValue: peerInfo.protocol_) ?? .http,
            download: peerInfo.download,
            ipAddress: pending.sourceIP,
            lastSeen: Date()
        )

        let session = ShareSession(
            id: sessionId,
            direction: .receiving,
            peer: peer,
            files: Array(fileMap.values),
            state: .active(filesCompleted: 0, filesTotal: fileMap.count),
            startedAt: Date(),
            savedTo: dest
        )
        activeSessions.append(session)
        powerAssertion.begin(reason: "HaloShare receiving file transfer")

        pending.continuation?.resume(returning: response)
        pendingConsent = nil
    }

    func rejectTransfer() {
        pendingConsent?.continuation?.resume(returning: nil)
        pendingConsent = nil
    }

    // MARK: - Save Directory

    func setSaveDirectory(_ url: URL) {
        saveDirectory = url
    }

    func currentSaveDirectory() -> URL {
        saveDirectory
    }

    // MARK: - Refresh Discovery

    func refreshDevices() async {
        await discovery.broadcastAnnounce()
        let scanned = await discovery.scanSubnet()
        for device in scanned {
            handleDiscoveredDevice(device)
        }
    }

    // MARK: - Private

    private func handleDiscoveredDevice(_ device: ShareDevice) {
        if let idx = discoveredDevices.firstIndex(where: { $0.fingerprint == device.fingerprint }) {
            discoveredDevices[idx] = device
        } else {
            discoveredDevices.append(device)
        }
    }

    private func expireStaleDevices() {
        let cutoff = Date().addingTimeInterval(-120) // 2 min
        discoveredDevices.removeAll { $0.lastSeen < cutoff }
    }

    private func handleIncomingPrepareUpload(request: PrepareUploadRequest, sourceIP: String) async -> PrepareUploadResponse? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.pendingConsent = IncomingTransfer(
                    request: request,
                    sourceIP: sourceIP,
                    continuation: continuation
                )
            }
        }
    }

    private func handleFileReceived(sessionId: String, fileId: String, url: URL) {
        guard let idx = activeSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        if let fileIdx = activeSessions[idx].files.firstIndex(where: { $0.id == fileId }) {
            activeSessions[idx].files[fileIdx].status = .completed
            activeSessions[idx].files[fileIdx].destURL = url
        }

        let completed = activeSessions[idx].files.filter { $0.status == .completed }.count
        let total = activeSessions[idx].files.count
        activeSessions[idx].state = .active(filesCompleted: completed, filesTotal: total)

        if completed == total {
            activeSessions[idx].state = .completed
            activeSessions[idx].completedAt = Date()
            powerAssertion.end()

            let session = activeSessions[idx]
            let record = TransferRecord(
                id: sessionId,
                peerAlias: session.peer.alias,
                peerFingerprint: session.peer.fingerprint,
                direction: .receiving,
                fileCount: total,
                totalBytes: session.files.reduce(0) { $0 + $1.size },
                date: Date(),
                status: .completed,
                fileNames: session.files.map(\.fileName)
            )
            transferHistory.insert(record, at: 0)
            saveHistory()

            postNotification(title: "Files Received", body: "Received \(total) file(s) from \(session.peer.alias)")

            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    self.activeSessions.removeAll { $0.id == sessionId }
                }
            }
        }
    }

    private func handleReceiveProgress(sessionId: String, fileId: String, bytes: Int64) {
        guard let idx = activeSessions.firstIndex(where: { $0.id == sessionId }),
              let fileIdx = activeSessions[idx].files.firstIndex(where: { $0.id == fileId }) else { return }
        activeSessions[idx].files[fileIdx].bytesTransferred = bytes
        activeSessions[idx].files[fileIdx].status = .transferring
    }

    private func handleSessionCancelled(sessionId: String) {
        guard let idx = activeSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        activeSessions[idx].state = .cancelled
        powerAssertion.end()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                self.activeSessions.removeAll { $0.id == sessionId }
            }
        }
    }

    private func updateSendProgress(sessionId: String, fileId: String, bytesSent: Int64, totalBytes: Int64) {
        guard let idx = activeSessions.firstIndex(where: { $0.id == sessionId }),
              let fileIdx = activeSessions[idx].files.firstIndex(where: { $0.id == fileId }) else { return }
        activeSessions[idx].files[fileIdx].bytesTransferred = bytesSent
        activeSessions[idx].files[fileIdx].status = .transferring

        if bytesSent >= totalBytes {
            activeSessions[idx].files[fileIdx].status = .completed
            let completed = activeSessions[idx].files.filter { $0.status == .completed }.count
            activeSessions[idx].state = .active(filesCompleted: completed, filesTotal: activeSessions[idx].files.count)
        }
    }

    // MARK: - File Helpers

    private func expandURLsToShareFiles(_ urls: [URL]) -> [ShareFile] {
        var files: [ShareFile] = []
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let baseName = url.lastPathComponent
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }
                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                          values.isDirectory != true else { continue }
                    let relativePath = baseName + "/" + fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                    files.append(ShareFile(
                        id: UUID().uuidString,
                        fileName: relativePath,
                        size: Int64(values.fileSize ?? 0),
                        fileType: mimeType(for: fileURL),
                        sourceURL: fileURL
                    ))
                }
            } else {
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                files.append(ShareFile(
                    id: UUID().uuidString,
                    fileName: url.lastPathComponent,
                    size: size,
                    fileType: mimeType(for: url),
                    sourceURL: url
                ))
            }
        }
        return files
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let mimeMap: [String: String] = [
            "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
            "gif": "image/gif", "pdf": "application/pdf", "zip": "application/zip",
            "mp4": "video/mp4", "mov": "video/quicktime", "mp3": "audio/mpeg",
            "txt": "text/plain", "html": "text/html", "json": "application/json",
            "doc": "application/msword", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ]
        return mimeMap[ext] ?? "application/octet-stream"
    }

    // MARK: - Notifications

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - History Persistence

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "haloShareHistory"),
              let records = try? JSONDecoder().decode([TransferRecord].self, from: data) else { return }
        transferHistory = records
    }

    private func saveHistory() {
        let capped = Array(transferHistory.prefix(100))
        transferHistory = capped
        guard let data = try? JSONEncoder().encode(capped) else { return }
        UserDefaults.standard.set(data, forKey: "haloShareHistory")
    }
}
