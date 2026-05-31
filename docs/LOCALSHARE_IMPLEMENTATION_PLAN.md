# HaloShare — Local File Transfer Implementation Plan
## LocalSend-Compatible Protocol · macOS Swift · Background-Safe

> Research base: LocalSend Protocol v2.1 · https://github.com/localsend/localsend
> Target: Halo v3.0 · New sidebar module `.localShare`
> Date: 2026-05-31

---

## 1. Protocol Summary (What We're Building Against)

| Parameter | Value |
|-----------|-------|
| Protocol version | 2.1 |
| TCP/UDP port | **53317** (default, configurable) |
| Multicast address | **224.0.0.167:53317** (UDP) |
| HTTP transport | HTTPS (self-signed cert) OR HTTP |
| Device fingerprint | SHA-256 of TLS cert DER bytes |
| Max concurrent uploads | 4 recommended |
| Compatibility | LocalSend apps on iOS, Android, Windows, Linux, macOS |

### Core Endpoints (all under `/api/localsend/v2/`)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/register` | Two-way device discovery exchange |
| POST | `/prepare-upload` | Initiate transfer session (sender → receiver) |
| POST | `/upload?sessionId=&fileId=&token=` | Send file binary data |
| POST | `/cancel?sessionId=` | Abort session |
| GET | `/info` | Read-only device info |
| POST | `/prepare-download` | Initiate download session (receiver pulls) |
| GET | `/download?sessionId=&fileId=` | Pull file from sender |

---

## 2. Architecture Overview

```
Halo/
├── Core/LocalShare/
│   ├── Models/
│   │   └── LocalShareModels.swift          — all DTOs, session state, device model
│   ├── Crypto/
│   │   └── TLSManager.swift                — self-signed cert, fingerprint, keychain
│   ├── Network/
│   │   ├── MulticastDiscovery.swift        — UDP 224.0.0.167 listener + broadcaster
│   │   ├── LocalShareServer.swift          — NWListener HTTP/HTTPS server (receive side)
│   │   ├── LocalShareClient.swift          — URLSession sender (send side)
│   │   └── BackgroundTransferDelegate.swift — URLSession background delegate
│   └── Manager/
│       └── LocalShareManager.swift         — @MainActor singleton, wires everything
│
├── Features/LocalShare/
│   ├── LocalShareView.swift                — main module view
│   ├── DeviceListView.swift                — discovered devices browser
│   ├── FileSendView.swift                  — drag-drop + file picker + send progress
│   ├── ReceiveConsentView.swift            — incoming request accept/reject sheet
│   ├── TransferProgressView.swift         — live progress rows (both directions)
│   └── TransferHistoryView.swift          — completed transfers log
```

### Singleton Dependency Graph

```
AppState
  └─ LocalShareManager (@MainActor singleton)
       ├─ TLSManager           — cert lifecycle, fingerprint
       ├─ MulticastDiscovery   — announces + listens on UDP 53317
       ├─ LocalShareServer     — NWListener, handles all incoming HTTP
       └─ LocalShareClient     — URLSession (foreground + background sessions)
```

---

## 3. Data Models (`LocalShareModels.swift`)

```swift
// ── Device ─────────────────────────────────────────────────────────────
struct ShareDevice: Identifiable, Codable, Equatable {
    var id: String { fingerprint }
    var alias:       String          // display name
    var version:     String          // protocol version "2.1"
    var deviceModel: String?
    var deviceType:  DeviceType?
    var fingerprint: String          // SHA-256 or random hex
    var port:        Int             // 53317 default
    var protocol_:   TransportProtocol // "http" | "https"
    var download:    Bool?
    var ipAddress:   String          // populated locally, not in protocol
    var lastSeen:    Date
}

enum DeviceType:    String, Codable { case mobile, desktop, web, headless, server }
enum TransportProtocol: String, Codable { case http, https }

// ── Transfer Session ────────────────────────────────────────────────────
struct ShareSession: Identifiable {
    enum Direction { case sending, receiving }
    enum State {
        case waitingForConsent           // receiver pending user decision
        case active(filesCompleted: Int, filesTotal: Int)
        case paused                      // app backgrounded (transfer continues via BG session)
        case completed
        case failed(String)
        case cancelled
    }

    var id:          String             // sessionId from /prepare-upload
    var direction:   Direction
    var peer:        ShareDevice
    var files:       [ShareFile]
    var state:       State
    var startedAt:   Date
    var completedAt: Date?
    var savedTo:     URL?               // receive destination
}

// ── File Entry ──────────────────────────────────────────────────────────
struct ShareFile: Identifiable, Codable {
    var id:         String              // unique within session
    var fileName:   String              // includes relative path for folders: "docs/readme.txt"
    var size:       Int64
    var fileType:   String              // MIME type
    var sha256:     String?
    var preview:    String?             // base64 image thumbnail
    var metadata:   FileMetadata?
    // local state (not in protocol)
    var sourceURL:  URL?                // sender: local file to read
    var destURL:    URL?                // receiver: where to save
    var token:      String?             // token from prepare-upload response
    var bytesTransferred: Int64 = 0
    var status:     FileStatus = .pending

    enum FileStatus { case pending, transferring, completed, failed(String) }
}

struct FileMetadata: Codable {
    var modified: String?              // ISO 8601
    var accessed: String?
}

// ── Wire DTOs (JSON serialisation) ─────────────────────────────────────
struct DeviceInfoDTO: Codable {
    var alias, version: String
    var deviceModel: String?
    var deviceType:  String?
    var fingerprint: String
    var port: Int
    var protocol_:   String
    var download:    Bool?
    var announce:    Bool?
    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, announce
        case protocol_ = "protocol"
    }
}

struct PrepareUploadRequest: Codable {
    var info:  DeviceInfoDTO
    var files: [String: FileDTOUpload]      // fileId → FileDTO
}

struct FileDTOUpload: Codable {
    var id, fileName, fileType: String
    var size: Int64
    var sha256, preview: String?
    var metadata: FileMetadata?
}

struct PrepareUploadResponse: Codable {
    var sessionId: String
    var files: [String: String]             // fileId → token
}

struct MulticastAnnounce: Codable {
    var alias, version: String
    var deviceModel, deviceType: String?
    var fingerprint: String
    var port: Int
    var protocol_: String
    var download: Bool?
    var announce: Bool
    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, announce
        case protocol_ = "protocol"
    }
}
```

---

## 4. TLS Certificate Manager (`TLSManager.swift`)

```swift
// Responsibilities:
// • Generate RSA-2048 self-signed X.509 certificate on first launch
// • Store cert + private key in Keychain (kSecClassCertificate)
// • Expose fingerprint as SHA-256(DER bytes) hex string
// • Provide SecIdentity for NWListener TLS configuration
// • Provide trust evaluation bypass for URLSession (self-signed)

final class TLSManager {
    static let shared = TLSManager()

    private(set) var fingerprint: String = ""     // 64-char hex SHA-256

    func loadOrCreate() throws { ... }
    // Uses SecKeyCreateRandomKey + SecCertificateCreateWithData
    // Stores in Keychain with kSecAttrLabel = "com.halo.mac.localshare"

    func nwParameters() -> NWParameters { ... }
    // Returns NWParameters with TLS using the stored identity
    // Disables certificate chain verification (self-signed)

    func urlSessionDelegate() -> URLSessionDelegate { ... }
    // Returns delegate that trusts our specific fingerprint
}
```

**Implementation detail (cert generation):**
```swift
// 1. Generate RSA key pair via SecKeyCreateRandomKey
// 2. Build X.509 cert using Security.framework (or manually DER encode)
// 3. Compute SHA-256 of DER bytes → fingerprint
// 4. Store SecIdentity in Keychain
// 5. On URLSession side: URLSessionTaskDelegate.urlSession(_:didReceive:completionHandler:)
//    → compare server cert SHA-256 with stored fingerprint of known device
```

---

## 5. Multicast Discovery (`MulticastDiscovery.swift`)

### Why raw Darwin sockets, not Bonjour
LocalSend uses a specific multicast group (224.0.0.167) with a custom JSON payload.
Bonjour (mDNS over 224.0.0.251) is a different protocol and not compatible.
We must use `Darwin.socket` / CFSocket to join the multicast group.

```swift
actor MulticastDiscovery {
    // ── Listener ─────────────────────────────────────────────────────
    // Creates UDP socket, setsockopt IP_ADD_MEMBERSHIP on 224.0.0.167
    // Receives DeviceInfoDTO announcements and calls back on discovery

    func startListening(onDevice: @escaping (ShareDevice, String) -> Void) async throws

    // ── Broadcaster ──────────────────────────────────────────────────
    // Sends our DeviceInfoDTO + announce:true to multicast group
    // Also sends announce:false responses to incoming requests

    func broadcastAnnounce() async               // periodic, every 30s
    func replyTo(ip: String, port: Int) async    // HTTP POST /register reply

    // ── Implementation notes ────────────────────────────────────────
    // Socket setup:
    //   socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    //   setsockopt(SO_REUSEADDR + SO_REUSEPORT)
    //   setsockopt(IP_ADD_MEMBERSHIP, ip_mreq { 224.0.0.167, INADDR_ANY })
    //   bind to 0.0.0.0:53317
    // Multicast TTL: setsockopt(IP_MULTICAST_TTL, 1)  ← local subnet only
    // Loop: setsockopt(IP_MULTICAST_LOOP, 0)           ← don't receive own packets
}
```

**Fallback: Subnet scan**
If multicast fails (some routers block it):
```swift
func scanSubnet() async {
    // Get local IP, compute subnet (e.g., 192.168.1.0/24)
    // Parallel HTTP POST to .1–.254 with timeout 500ms
    // Collect responding devices
}
```

---

## 6. HTTP Server (`LocalShareServer.swift`)

Uses `Network.framework`'s `NWListener` — no third-party dependencies.

```swift
actor LocalShareServer {
    private var listener: NWListener?

    func start(port: UInt16 = 53317, tls: NWParameters) async throws
    func stop()

    // Routes dispatcher — parses HTTP manually from NWConnection data stream
    // Routes: POST /api/localsend/v2/register
    //         POST /api/localsend/v2/prepare-upload
    //         POST /api/localsend/v2/upload      (streaming body → file)
    //         POST /api/localsend/v2/cancel
    //         GET  /api/localsend/v2/info
}
```

### HTTP Parser
Since NWListener delivers raw bytes, we need a lightweight HTTP/1.1 parser:
```
Read bytes until "\r\n\r\n" (header/body boundary)
Parse: method, path, query params, Content-Length header
Body: continue reading Content-Length bytes
```

### Critical: Streaming File Save (`/upload` endpoint)
```swift
// MUST NOT buffer entire file in memory for large files
// Streaming approach:
// 1. Open FileHandle for writing at destURL
// 2. As bytes arrive from NWConnection, write incrementally
// 3. Track bytesReceived; call progress callback every 256KB
// 4. Close when Content-Length bytes received
// 5. Verify SHA-256 if provided in prepare-upload metadata
```

### Incoming Transfer Consent Flow
```
1. /prepare-upload arrives → parse files metadata
2. Emit event to LocalShareManager (on @MainActor)
3. Show ReceiveConsentView sheet (file list + sender info + Accept/Reject)
4. User action:
   Accept → generate sessionId + per-file tokens → respond 200
   Reject → respond 403
   Timeout (30s) → respond 403
5. Begin accepting /upload requests for this session
```

---

## 7. HTTP Client / Sender (`LocalShareClient.swift`)

### Foreground Transfers (URLSession + streaming upload)

```swift
final class LocalShareClient: NSObject {
    // Foreground session — used when app is active
    private lazy var session: URLSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )

    // Background session — used when app moves to background mid-transfer
    private lazy var bgSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.halo.mac.localshare.bg"
        )
        config.isDiscretionary      = false
        config.sessionSendsLaunchEvents = true   // wake app on completion
        config.allowsCellularAccess = false      // local network only
        config.timeoutIntervalForRequest  = 300  // 5 min (large files)
        config.timeoutIntervalForResource = 3600 // 1 hr (whole session)
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // ── Send flow ─────────────────────────────────────────────────────

    func prepareUpload(to device: ShareDevice, files: [ShareFile]) async throws
        -> PrepareUploadResponse

    func uploadFile(_ file: ShareFile, session: ShareSession) async throws
    // Uses URLSession uploadTask(with:fromFile:)
    // File URL is streamed; no full in-memory copy
    // Progress via URLSessionTaskDelegate.urlSession(_:task:didSendBodyData:)

    func cancelSession(_ sessionId: String, on device: ShareDevice) async

    // ── Parallel upload orchestration ─────────────────────────────────

    func sendAll(files: [ShareFile], to device: ShareDevice) async throws {
        let response = try await prepareUpload(to: device, files: files)
        // TaskGroup with max 4 concurrent uploads
        await withThrowingTaskGroup(of: Void.self) { group in
            var active = 0
            for file in files {
                if active >= 4 { try await group.next() ; active -= 1 }
                let token = response.files[file.id] ?? ""
                group.addTask {
                    try await self.uploadFile(file.with(token: token), session: ...)
                }
                active += 1
            }
            try await group.waitForAll()
        }
    }
}
```

### Background URLSession Delegate
```swift
// BackgroundTransferDelegate.swift
// In HaloApp.swift:
//   .onReceive(NotificationCenter.default.publisher(for: .localShareBGComplete)) { ... }
//
// AppDelegate equivalent (in HaloApp @main):
//   func application(_ application: NSApplication,
//                    handleEventsForBackgroundURLSession identifier: String,
//                    completionHandler: @escaping () -> Void)
//   → Store completionHandler, call after processing background events

extension LocalShareClient: URLSessionDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        LocalShareManager.shared.handleBackgroundCompletion()
    }
}
```

---

## 8. Background Transfer Architecture

This is the most complex requirement. Here's how it works:

### macOS Background vs iOS Background
Unlike iOS (strict background limits), macOS apps:
- Continue running in background by default
- Can hold `NSBackgroundActivityScheduler` for ongoing work
- The main concern is **app quit** — user closes Halo while transfer runs

### Solution: Hybrid Approach
```
Phase 1 — App Active/Background: Standard URLSession foreground
  ↓ App moves to background
Phase 2 — App in Background: URLSession continues (macOS allows this)
  ↓ App is quit by user (rare, but handle it)
Phase 3 — App Relaunched by system: Background URLSession completion events
```

### Process Assertion (prevents system sleep during large transfers)
```swift
import IOKit.pwr_mgt

final class TransferPowerAssertion {
    var assertionID: IOPMAssertionID = 0

    func begin(reason: String) {
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
    }
    func end() { IOPMAssertionRelease(assertionID) }
}
```

### Transfer State Persistence
Save active sessions to UserDefaults/SQLite so they survive app restart:
```swift
// On transfer start: persist session metadata
UserDefaults.standard.set(try! JSONEncoder().encode(session), forKey: "activeSession_\(session.id)")

// On app launch: check for incomplete sessions, offer resume
func recoverPendingSessions() { ... }
```

---

## 9. Large File Support

### Critical constraints:
- File size: no protocol limit (tested with files >10 GB in LocalSend)
- Memory: MUST stream, never buffer entire file in RAM
- Time: May take hours for very large files

### Sender side (URLSession uploadTask with fileURL)
```swift
// URLSession automatically streams from file URL — no manual chunking needed
var request = URLRequest(url: uploadURL)
request.httpMethod = "POST"
request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")
// Use file URL, not data — URLSession streams it from disk
let task = session.uploadTask(with: request, fromFile: file.sourceURL!)
task.resume()
```

### Receiver side (NWConnection incremental write)
```swift
func receiveStream(connection: NWConnection, to destURL: URL,
                   expectedSize: Int64, progress: (Int64) -> Void) async throws {
    let handle = try FileHandle(forWritingTo: destURL)
    defer { try? handle.close() }
    var received: Int64 = 0
    while received < expectedSize {
        let chunk = try await connection.receiveChunk(max: 1024 * 256) // 256 KB
        handle.write(chunk)
        received += Int64(chunk.count)
        if received % (1024 * 1024) == 0 { progress(received) } // every 1 MB
    }
}
```

### Timeout configuration
```swift
// URLSession timeouts for large files:
config.timeoutIntervalForRequest  = 60     // 60s to start receiving response
config.timeoutIntervalForResource = 86400  // 24h for entire resource (multi-GB)
// Note: timeoutIntervalForRequest resets on each data received — so 60s of silence aborts
```

---

## 10. Folder Transfer Support

### Protocol approach (LocalSend-compatible)
The protocol has no special folder type. Folders are sent as individual files with **relative paths embedded in `fileName`**:

```
folder/
├── readme.txt        → fileName: "folder/readme.txt"
├── images/
│   ├── photo1.jpg    → fileName: "folder/images/photo1.jpg"
│   └── photo2.png    → fileName: "folder/images/photo2.png"
└── data.json         → fileName: "folder/data.json"
```

### Sender: recursive enumeration
```swift
func enumerateFolder(_ url: URL, base: URL) -> [ShareFile] {
    var files: [ShareFile] = []
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [
        .fileSizeKey, .contentModificationDateKey, .isDirectoryKey
    ]) else { return [] }
    for case let fileURL as URL in enumerator {
        let resourceValues = try! fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if resourceValues.isDirectory == true { continue }
        let relativePath = fileURL.path.replacingOccurrences(of: base.path + "/", with: "")
        files.append(ShareFile(
            id:       UUID().uuidString,
            fileName: relativePath,      // ← relative path is the key
            size:     Int64(resourceValues.fileSize ?? 0),
            fileType: mimeType(for: fileURL),
            sourceURL: fileURL
        ))
    }
    return files
}
```

### Receiver: directory creation
```swift
func destinationURL(for file: ShareFile, base: URL) -> URL {
    let dest = base.appendingPathComponent(file.fileName) // preserves subdirs
    try? FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    return dest
}
```

---

## 11. Resume / Recovery

### Session persistence model
```swift
// LocalShareSessionStore.swift
// Persists active sessions to JSON in ~/Library/Application Support/com.halo.mac/shares/

struct PersistedSession: Codable {
    var sessionId: String
    var peerDevice: ShareDevice
    var files: [ShareFile]
    var bytesTransferred: [String: Int64]   // fileId → bytes
    var direction: String                    // "sending" | "receiving"
    var createdAt: Date
    var destDirectory: URL?
}
```

### Resume scenario (sending)
1. App killed mid-transfer
2. On next launch: find persisted sessions with incomplete files
3. Show "Resume pending transfer to [DeviceName]?" dialog
4. Re-initiate: POST `/prepare-upload` (new session → new sessionId + tokens)
5. Upload only files that weren't completed (using `bytesTransferred` map)

> **Note:** The LocalSend protocol does NOT support partial file resume (no byte-range).
> Incomplete files must be fully re-uploaded. However, fully completed files are skipped.

### Resume scenario (receiving)
1. Incomplete files are kept in `~/Library/Application Support/com.halo.mac/shares/pending/`
2. On cleanup: remove after 24h if not completed
3. No protocol support for receiver-initiated resume (sender must re-send)

---

## 12. LocalShareManager (Coordinator)

```swift
@MainActor
final class LocalShareManager: ObservableObject {
    static let shared = LocalShareManager()

    // Published state
    @Published var discoveredDevices: [ShareDevice] = []
    @Published var activeSessions: [ShareSession]   = []
    @Published var transferHistory: [TransferRecord] = []
    @Published var pendingConsent: ShareSession?     // incoming transfer awaiting decision

    // Sub-systems
    private let tls:       TLSManager       = .shared
    private let discovery: MulticastDiscovery
    private let server:    LocalShareServer
    private let client:    LocalShareClient

    // ── Lifecycle ─────────────────────────────────────────────────────

    func start() async throws {
        try tls.loadOrCreate()
        try await server.start(port: 53317, tls: tls.nwParameters())
        await discovery.startListening { [weak self] device, ip in
            Task { @MainActor in self?.handleDiscoveredDevice(device, ip: ip) }
        }
        await discovery.broadcastAnnounce()
    }

    func stop() async {
        await discovery.stop()
        await server.stop()
    }

    // ── Sending ───────────────────────────────────────────────────────

    func send(files: [URL], to device: ShareDevice) async throws {
        // Expand folders → flat file list with relative paths
        // Create ShareSession
        // Start transfer via client.sendAll()
        // Persist session state
    }

    // ── Receiving ─────────────────────────────────────────────────────

    func acceptTransfer(_ session: ShareSession) {
        // Generate sessionId + tokens
        // Signal server to respond 200 to waiting /prepare-upload
        // Start accepting /upload requests
    }

    func rejectTransfer(_ session: ShareSession) {
        // Signal server to respond 403
    }

    // ── Background handling ───────────────────────────────────────────

    func handleBackgroundCompletion() {
        // Called by URLSession background delegate
        // Update session states
        // Post local notification
        // Persist completion to history
    }
}
```

---

## 13. UI Components

### LocalShareView (Main Module View)

```
LocalShareView
├── Top: Device Scanner bar
│   ├── "Searching for nearby devices..." (animated)
│   └── [Refresh] [Manual IP entry]
├── Discovered Devices Grid (2-col)
│   └── DeviceCard: icon + name + model + "Tap to send"
├── Active Transfers Section
│   └── TransferRow: direction icon + filename/count + progress bar + speed
└── Recent Transfers Section
    └── HistoryRow: peer name + file count + size + date + status
```

### ReceiveConsentView (Sheet)

```
ReceiveConsentView (shown as modal sheet)
├── Header: sender device icon + name + IP
├── File list (scrollable):
│   └── FileRow: icon + name + size + (folder badge if applicable)
├── Total: "X files · Y MB"
├── Destination picker: ~/Downloads [Change...]
└── Buttons: [Reject] [Accept All] [Accept Selected...]
```

### TransferProgressView (Live row)

```
TransferProgressView
├── [←/→ direction icon] [Device icon] DeviceName
├── "file.pdf  2.3/4.1 MB  (1.2 MB/s  ~1m 32s)"
├── [▓▓▓▓▓▓▓▓░░░░]  56%
└── [Cancel X]
```

---

## 14. Implementation Phases & Milestones

### Phase 0 — Foundation (3-4 days)
- [ ] `LocalShareModels.swift` — all DTOs + session state machine
- [ ] `TLSManager.swift` — cert generation, fingerprint, Keychain storage
- [ ] Wire `AppModule.localShare` into sidebar + ContentView routing
- [ ] Register new files in `project.pbxproj`
- [ ] Scaffold placeholder `LocalShareView`
- [ ] Add `AppState.localShareManager` init call

### Phase 1 — Device Discovery (2-3 days)
- [ ] `MulticastDiscovery.swift` — UDP multicast join on 224.0.0.167:53317
- [ ] Parse DeviceInfoDTO announcements from UDP
- [ ] Broadcast our own announce payload every 30s
- [ ] `/api/localsend/v2/register` HTTP handler (server side)
- [ ] HTTP POST to `/register` on discovered IPs (client side)
- [ ] `DeviceListView` — show live-updating device list with indicators
- [ ] Subnet scan fallback (parallel HTTP to .1–.254, 500ms timeout)

### Phase 2 — File Receiving (4-5 days)
- [ ] `LocalShareServer.swift` — `NWListener` on port 53317 with TLS
- [ ] HTTP/1.1 parser (header + streaming body)
- [ ] `/prepare-upload` handler → emit consent event → await user decision
- [ ] `ReceiveConsentView` — accept/reject sheet with file list
- [ ] `/upload` handler — streaming file write via `FileHandle`
- [ ] `/cancel` handler — abort active sessions
- [ ] Destination folder picker (`~/Downloads` default)
- [ ] SHA-256 verification on received files (if sender provided hash)
- [ ] Local notification on transfer complete (works when app in background)

### Phase 3 — File Sending (3-4 days)
- [ ] `LocalShareClient.swift` — URLSession foreground + background configs
- [ ] `prepareUpload()` — POST `/prepare-upload` + parse response
- [ ] `uploadFile()` — `uploadTask(with:fromFile:)` streaming upload
- [ ] Parallel upload orchestration (max 4 concurrent via `TaskGroup`)
- [ ] Progress callbacks → publish to `LocalShareManager`
- [ ] `TransferProgressView` — live speed + ETA + progress bar
- [ ] Drag-and-drop support in `FileSendView`
- [ ] File picker (NSOpenPanel) + folder picker

### Phase 4 — Folder Transfer (2 days)
- [ ] `enumerateFolder()` — recursive with relative-path fileName encoding
- [ ] Receiver: `destinationURL(for:base:)` — create subdirectory tree
- [ ] UI: folder display in file list (collapsed tree or flat with path)

### Phase 5 — Background Mode & Resume (3 days)
- [ ] URLSession background configuration with identifier
- [ ] `BackgroundTransferDelegate` — `urlSessionDidFinishEvents`
- [ ] `TransferPowerAssertion` — IOPMAssertion to prevent sleep
- [ ] `LocalShareSessionStore` — persist session state to disk
- [ ] Resume dialog on app relaunch (incomplete sessions)
- [ ] Status bar icon badge for background transfers
- [ ] Progress in macOS menu bar (optional: small progress indicator)

### Phase 6 — Polish & Security (2 days)
- [ ] Certificate fingerprint verification for known devices
- [ ] IP validation on upload (must match prepare-upload source IP)
- [ ] Rate limiting on `/prepare-upload` (prevent PIN brute-force)
- [ ] Error dialogs with actionable messages
- [ ] Retry logic (3x with exponential backoff for 5xx errors)
- [ ] `TransferHistoryView` with search + filter

### Phase 7 — Testing (3 days)
- [ ] Unit: DTO serialisation round-trip
- [ ] Unit: fingerprint SHA-256 computation
- [ ] Unit: folder path encoding/decoding
- [ ] Integration: loopback send + receive (same machine, two ports)
- [ ] Integration: real LocalSend app on phone (cross-compatibility test)
- [ ] Large file test: >1 GB file, verify no memory spike
- [ ] Background test: start transfer, Cmd+H hide app, verify completion + notification
- [ ] Resume test: kill app mid-transfer, relaunch, resume

---

## 15. File & UUID Assignments for pbxproj

| UUID pair | File |
|-----------|------|
| `7100` / `7101` | `LocalShareModels.swift` |
| `7102` / `7103` | `TLSManager.swift` |
| `7104` / `7105` | `MulticastDiscovery.swift` |
| `7106` / `7107` | `LocalShareServer.swift` |
| `7108` / `7109` | `LocalShareClient.swift` |
| `7110` / `7111` | `BackgroundTransferDelegate.swift` |
| `7112` / `7113` | `LocalShareManager.swift` |
| `7114` / `7115` | `LocalShareView.swift` |
| `7116` / `7117` | `DeviceListView.swift` |
| `7118` / `7119` | `FileSendView.swift` |
| `7120` / `7121` | `ReceiveConsentView.swift` |
| `7122` / `7123` | `TransferProgressView.swift` |
| `7124` / `7125` | `TransferHistoryView.swift` |
| `7126` / `7127` | `LocalShareSessionStore.swift` |

---

## 16. New Entitlements Required

`Halo-Debug.entitlements` additions:
```xml
<!-- Local network access -->
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>

<!-- File access for receive directory -->
<key>com.apple.security.files.downloads.read-write</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

`Info.plist` additions:
```xml
<!-- Required for NWListener on macOS 13+ -->
<key>NSLocalNetworkUsageDescription</key>
<string>Halo uses the local network to discover and transfer files with nearby devices running Halo or LocalSend.</string>
<key>NSBonjourServices</key>
<array>
    <string>_localsend._tcp</string>
</array>
```

---

## 17. Key Risks & Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Multicast blocked by router | Medium | Subnet scan fallback + manual IP entry |
| TLS cert trust issues | Low | Store fingerprint per device, bypass chain validation |
| Background transfer killed by OS | Low (macOS) | URLSession bg config + IOPMAssertion |
| Large file OOM on receiver | Low | Streaming write — never buffer full file |
| Port 53317 in use | Low | Auto-retry on 53318, 53319… + user config |
| Partial folder transfers on failure | Medium | Per-file status tracking + resume on next attempt |
| Cross-platform incompatibility | Low | Strict adherence to LocalSend Protocol v2.1 spec |
| Sandbox file access restrictions | Medium | Use security-scoped bookmarks for user-selected files |

---

## 18. Dependencies

**Zero external dependencies.** All using native Apple frameworks:
- `Network.framework` — NWListener, NWConnection, NWBrowser
- `Security.framework` — TLS cert generation, Keychain, SHA-256
- `Foundation` — URLSession, JSON Codable, FileManager
- `IOKit` — Power management assertions
- Darwin C sockets — UDP multicast join

---

## 19. Compatibility Promise

This implementation will be fully compatible with:
- LocalSend for iOS
- LocalSend for Android
- LocalSend for Windows
- LocalSend for Linux

Any device running LocalSend will discover Halo and be able to exchange files bidirectionally.

---

*Plan authored: 2026-05-31 | Protocol: LocalSend v2.1 | Implementation: Halo v3.0*
