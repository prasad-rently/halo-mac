import Foundation
import SwiftUI

// MARK: - File System Models

struct ScannedItem: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let size: Int64
    let creationDate: Date?
    let modifiedDate: Date?
    let kind: FileKind
    var isSelected: Bool = true

    var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var name: String { url.lastPathComponent }
    var parentPath: String { url.deletingLastPathComponent().path }
    var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    var parentDisplayPath: String {
        parentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

enum FileKind: String, Sendable {
    case cache = "Cache"
    case log = "Log"
    case temp = "Temp"
    case download = "Download"
    case userFile = "User File"
    case appSupport = "App Support"
    case derived = "Derived Data"
    case iosBackup = "iOS Backup"
    case languagePack = "Language Pack"
    case other = "Other"

    var icon: String {
        switch self {
        case .cache: return "internaldrive"
        case .log: return "doc.text"
        case .temp: return "clock.badge.xmark"
        case .download: return "arrow.down.circle"
        case .userFile: return "doc"
        case .appSupport: return "gearshape"
        case .derived: return "hammer"
        case .iosBackup: return "iphone"
        case .languagePack: return "globe"
        case .other: return "doc.questionmark"
        }
    }
}

// MARK: - Cleanup Models

struct CleanupCategory: Identifiable {
    let id: UUID = UUID()
    let kind: CleanupKind
    var items: [ScannedItem] = []
    var isScanning: Bool = false
    var isSelected: Bool = true

    var totalBytes: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.size } }
    var allBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalFormatted: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    var allFormatted: String { ByteCountFormatter.string(fromByteCount: allBytes, countStyle: .file) }
    var selectedCount: Int { items.filter(\.isSelected).count }
}

enum CleanupKind: String, CaseIterable, Identifiable {
    case systemCaches = "System Caches"
    case userCaches = "User Caches"
    case logFiles = "Log Files"
    case tempFiles = "Temp Files"
    case downloads = "Downloads"
    case trash = "Trash"
    case mailAttachments = "Mail Attachments"
    case xcodeData = "Xcode DerivedData"
    case iosBackups = "iOS Backups"
    case languagePacks = "Language Packs"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .systemCaches: return "server.rack"
        case .userCaches: return "internaldrive"
        case .logFiles: return "doc.text.fill"
        case .tempFiles: return "clock.badge.xmark"
        case .downloads: return "arrow.down.circle.fill"
        case .trash: return "trash.fill"
        case .mailAttachments: return "envelope.fill"
        case .xcodeData: return "hammer.fill"
        case .iosBackups: return "iphone"
        case .languagePacks: return "globe"
        }
    }

    var targetPaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .systemCaches:
            return ["\(home)/Library/Caches", "/private/var/folders"]
        case .userCaches:
            return ["\(home)/Library/Caches"]
        case .logFiles:
            return ["\(home)/Library/Logs", "/private/var/log"]
        case .tempFiles:
            return ["/private/tmp", "/private/var/tmp"]
        case .downloads:
            return ["\(home)/Downloads"]
        case .trash:
            // Use FileManager API so we get the correct Trash URL for the
            // current user on all mounted volumes, not just ~/.Trash
            let trashURLs = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)
            return trashURLs.map(\.path).filter {
                FileManager.default.fileExists(atPath: $0)
            }
        case .mailAttachments:
            return ["\(home)/Library/Mail"]
        case .xcodeData:
            return ["\(home)/Library/Developer/Xcode/DerivedData",
                    "\(home)/Library/Developer/CoreSimulator/Caches"]
        case .iosBackups:
            return ["\(home)/Library/Application Support/MobileSync/Backup"]
        case .languagePacks:
            return ["/Applications"]
        }
    }

    var ageThresholdDays: Int? {
        switch self {
        case .logFiles: return 30
        case .tempFiles: return 7
        case .downloads: return nil
        default: return nil
        }
    }
}

// MARK: - Smart Scan Result

struct SmartScanResult: Identifiable {
    let id: UUID = UUID()
    let date: Date
    let categoryResults: [CleanupCategory]
    let threatsFound: Int
    let loginItemsFound: Int

    var totalBytes: Int64 { categoryResults.reduce(0) { $0 + $1.allBytes } }
    var totalBytesFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

// MARK: - Protection Models

struct MalwareThreat: Identifiable {
    let id: UUID = UUID()
    let name: String
    let kind: ThreatKind
    let risk: ThreatRisk
    let filePath: String
    var isQuarantined: Bool = false
}

enum ThreatKind: String {
    case adware = "Adware"
    case keylogger = "Keylogger"
    case pup = "Potentially Unwanted"
    case hijacker = "Browser Hijacker"
    case ransomware = "Ransomware"
}

enum ThreatRisk: String {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var color: Color {
        switch self {
        case .low: return .haloGreen
        case .medium: return .haloAmber
        case .high: return .haloRed
        }
    }
}

struct AppPermission: Identifiable {
    let id: UUID = UUID()
    let kind: PermissionKind
    var grantedApps: [String]

    var count: Int { grantedApps.count }
    var severity: Double { Double(count) / 10.0 }
}

enum PermissionKind: String, CaseIterable {
    case camera = "Camera"
    case microphone = "Microphone"
    case location = "Location"
    case contacts = "Contacts"
    case calendar = "Calendars"
    case fullDisk = "Full Disk Access"
    case screenRecording = "Screen Recording"
    case accessibility = "Accessibility"

    var icon: String {
        switch self {
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .location: return "location.fill"
        case .contacts: return "person.2.fill"
        case .calendar: return "calendar"
        case .fullDisk: return "internaldrive.fill"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        }
    }
}

// MARK: - Performance Models

struct LoginItem: Identifiable {
    let id: UUID = UUID()
    let name: String
    let bundleIdentifier: String?
    let path: String
    var isEnabled: Bool
    let ramUsageMB: Double
    let lastLaunchedDate: Date?
    let kind: LoginItemKind
    var isSuspicious: Bool = false

    var isUnused: Bool {
        guard let date = lastLaunchedDate else { return true }
        return Date().timeIntervalSince(date) > (60 * 60 * 24 * 90)
    }
}

enum LoginItemKind {
    case appService, launchAgent, loginItem
}

struct SystemMaintenanceTask: Identifiable {
    let id: UUID = UUID()
    let title: String
    let description: String
    let icon: String
    var lastRunDate: Date?
    var isRunning: Bool = false

    var lastRunFormatted: String {
        guard let date = lastRunDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Application Models

struct InstalledApp: Identifiable {
    let id: UUID = UUID()
    let name: String
    let bundleIdentifier: String
    let version: String
    let path: String
    let sizeBytes: Int64
    let lastUsedDate: Date?
    let installDate: Date?
    var leftovers: [AppLeftover] = []

    var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    var isUnused: Bool {
        // nil means Spotlight has no record — we cannot say it's unused (it may
        // have been used before Spotlight indexed it, or may have launched from
        // a path Spotlight ignores).  Only flag as unused when we have a positive
        // last-used date AND it is older than 90 days.
        guard let date = lastUsedDate else { return false }
        return Date().timeIntervalSince(date) > (60 * 60 * 24 * 90)
    }
}

struct AppLeftover: Identifiable {
    let id: UUID = UUID()
    let url: URL
    let kind: LeftoverKind
    let sizeBytes: Int64
    var isSelected: Bool = true

    var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    var displayPath: String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

enum LeftoverKind: String {
    case preferences    = "Preferences"
    case appSupport     = "App Support"
    case cache          = "Cache"
    case container      = "Container"
    case groupContainer = "Group Container"
    case crashLogs      = "Crash Logs"
    // F-010: additional leftover locations
    case logs           = "Logs"
    case savedState     = "Saved State"
    case cookies        = "Cookies"
    case webkit         = "WebKit Data"
    case launchAgent    = "Launch Agent"
}

// MARK: - Duplicate Models

struct DuplicateGroup: Identifiable {
    let id: UUID = UUID()
    var items: [DuplicateItem]

    var wastedBytes: Int64 {
        guard items.count > 1 else { return 0 }
        return items.dropFirst().reduce(0) { $0 + $1.sizeBytes }
    }
    var wastedFormatted: String { ByteCountFormatter.string(fromByteCount: wastedBytes, countStyle: .file) }
}

struct DuplicateItem: Identifiable {
    let id: UUID = UUID()
    let url: URL
    let sizeBytes: Int64
    let modifiedDate: Date?
    var isMarkedForDeletion: Bool = false

    var displayPath: String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    var name: String { url.lastPathComponent }
    var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

// MARK: - Clipboard Models

struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    let content: ClipboardContent
    let copiedDate: Date
    let sourceApp: String?
    var isPinned: Bool

    init(id: UUID = UUID(), content: ClipboardContent, copiedDate: Date = Date(),
         sourceApp: String? = nil, isPinned: Bool = false) {
        self.id = id
        self.content = content
        self.copiedDate = copiedDate
        self.sourceApp = sourceApp
        self.isPinned = isPinned
    }

    var preview: String {
        switch content {
        case .text(let s): return s
        case .url(let u): return u.absoluteString
        case .code(let c, _): return c
        case .image(_, let meta): return meta ?? "Image"
        case .color(let hex): return hex
        }
    }

    var kind: ClipboardItemKind {
        switch content {
        case .text: return .text
        case .url: return .url
        case .code: return .code
        case .image: return .image
        case .color: return .color
        }
    }

    var copiedDateFormatted: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(copiedDate) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: copiedDate)
        } else if calendar.isDateInYesterday(copiedDate) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Yesterday \(formatter.string(from: copiedDate))"
        } else {
            let formatter = RelativeDateTimeFormatter()
            return formatter.localizedString(for: copiedDate, relativeTo: Date())
        }
    }
}

enum ClipboardContent: Equatable {
    case text(String)
    case url(URL)
    case code(String, language: String?)
    case image(Data, metadata: String?)
    case color(hex: String)
}

enum ClipboardItemKind: String, CaseIterable {
    case text = "Text"
    case url = "URL"
    case code = "Code"
    case image = "Image"
    case color = "Color"

    var icon: String {
        switch self {
        case .text: return "doc.text"
        case .url: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        case .color: return "paintpalette"
        }
    }

    var accentColor: Color {
        switch self {
        case .text: return .haloAccent
        case .url: return .haloCyan
        case .code: return .haloPurple
        case .image: return .haloGreen
        case .color: return .haloAmber
        }
    }
}

// MARK: - Activity Event

struct ActivityEvent: Identifiable {
    let id: UUID = UUID()
    let kind: ActivityKind
    let message: String
    let date: Date

    var dateFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

enum ActivityKind {
    case scanCompleted, cleanupDone, threatFound, appUninstalled, duplicatesRemoved, clipboardCleared

    var color: Color {
        switch self {
        case .scanCompleted, .cleanupDone, .duplicatesRemoved: return .haloGreen
        case .threatFound: return .haloRed
        case .appUninstalled, .clipboardCleared: return .haloAccent
        }
    }

    var icon: String {
        switch self {
        case .scanCompleted: return "checkmark.circle.fill"
        case .cleanupDone: return "sparkles"
        case .threatFound: return "exclamationmark.triangle.fill"
        case .appUninstalled: return "trash.fill"
        case .duplicatesRemoved: return "doc.on.doc.fill"
        case .clipboardCleared: return "doc.on.clipboard"
        }
    }
}

// MARK: - Sample Data

extension ActivityEvent {
    static let sampleEvents: [ActivityEvent] = [
        .init(kind: .scanCompleted, message: "Smart Scan completed — 3.8 GB found", date: Date().addingTimeInterval(-172800)),
        .init(kind: .cleanupDone, message: "Xcode derived data cleaned — 1.2 GB removed", date: Date().addingTimeInterval(-345600)),
        .init(kind: .scanCompleted, message: "3 apps with stale login items detected", date: Date().addingTimeInterval(-432000))
    ]
}

extension ClipboardItem {
    static let sampleItems: [ClipboardItem] = [
        .init(content: .url(URL(string: "https://developer.apple.com/documentation/swiftui/navigationsplitview")!),
              copiedDate: Date().addingTimeInterval(-120), sourceApp: "Safari", isPinned: true),
        .init(content: .code("let scanner = FileSystemScanner(rootURL: homeURL)", language: "swift"),
              copiedDate: Date().addingTimeInterval(-840), sourceApp: "Xcode"),
        .init(content: .text("Halo — Your Mac. Elevated."),
              copiedDate: Date().addingTimeInterval(-1920), sourceApp: "Notes"),
        .init(content: .image(Data(), metadata: "Screenshot 2026-05-03.png · 1440×900"),
              copiedDate: Date().addingTimeInterval(-3600), sourceApp: "Screenshot"),
        .init(content: .text("com.apple.security.app-sandbox = true"),
              copiedDate: Date().addingTimeInterval(-7200), sourceApp: "Xcode"),
        .init(content: .text("gokul@mavericks.io"),
              copiedDate: Date().addingTimeInterval(-90000), isPinned: true),
        .init(content: .url(URL(string: "https://github.com/mavericks-team/halo-app/pull/42")!),
              copiedDate: Date().addingTimeInterval(-93600), sourceApp: "Safari"),
        .init(content: .code("actor DuplicateDetector {\n    func detect(in urls: [URL]) async throws -> [DuplicateGroup]", language: "swift"),
              copiedDate: Date().addingTimeInterval(-100000), sourceApp: "Xcode")
    ]
}

// MARK: - Time Machine Backup Health (F-022)

/// Snapshot of Time Machine's real state, built entirely from `tmutil` output
/// and volume metadata. `isConfigured == false` means Halo found no Time
/// Machine destination at all — the UI must show an honest empty state, never
/// a fabricated "healthy" card or empty heatmap as if backups exist.
struct TimeMachineStatus: Sendable {
    var isConfigured: Bool
    var destinationName: String? = nil
    var mountPoint: String? = nil
    /// Set for network destinations (Time Capsule / NAS), which `tmutil`
    /// reports with a `URL` instead of a `Mount Point`.
    var destinationURL: String? = nil
    /// A network destination has no local mount path until its sparsebundle is
    /// mounted, so "no mount point" is not evidence that it is disconnected.
    var isNetworkDestination: Bool = false
    /// Whether the destination volume is currently mounted/reachable (it can
    /// be configured but disconnected, e.g. an external HDD that's unplugged).
    /// Only meaningful for local destinations — read `reachability` instead.
    var isReachable: Bool = false
    var availableBytes: Int64? = nil
    var totalBytes: Int64? = nil
    /// Most recent backup Halo could find, from `tmutil latestbackup` or,
    /// failing that, the newest entry in `tmutil listbackups`.
    var lastBackupDate: Date? = nil
    var isBackupRunning: Bool = false
    /// All snapshot dates found via `tmutil listbackups` — used to build the
    /// 30-day heatmap. Empty when unknown; never fabricated.
    var backupDates: [Date] = []

    static let notConfigured = TimeMachineStatus(isConfigured: false)

    /// True only when Halo has a real last-backup date and it's 48h+ old.
    /// Never true for "no data" — that's the separate `.notConfigured` state,
    /// or `hasNeverBackedUp` below.
    var isStale: Bool {
        guard isConfigured, let last = lastBackupDate else { return false }
        return Date().timeIntervalSince(last) > (48 * 3600)
    }

    /// Time Machine is set up but no backup has ever completed — a destination
    /// was selected and then the drive was never plugged in, or every attempt
    /// failed.
    ///
    /// This is deliberately separate from `isStale`, which cannot represent it:
    /// `isStale` needs a `lastBackupDate` to measure against, so with no
    /// backups at all it is `false`. Without this the app stayed silent in the
    /// one configuration where the user is most likely to believe they are
    /// protected and not be.
    var hasNeverBackedUp: Bool {
        isConfigured && lastBackupDate == nil
    }

    /// Whether Halo can actually tell that the destination is present.
    ///
    /// Split three ways rather than two because "the drive is unplugged" and
    /// "we have no way to measure this one" are different facts, and showing
    /// the second as the first is what made healthy network destinations read
    /// as disconnected.
    enum Reachability { case reachable, unreachable, unknown }

    var reachability: Reachability {
        if isReachable { return .reachable }
        if isNetworkDestination { return .unknown }
        return .unreachable
    }

    var spaceUsedRatio: Double? {
        guard let available = availableBytes, let total = totalBytes, total > 0 else { return nil }
        return 1 - (Double(available) / Double(total))
    }
}

/// One day's cell in the 30-day backup-frequency heatmap.
enum BackupDayState: Equatable {
    case backedUp   // a snapshot exists for this calendar day
    case late       // 1 day since the most recent snapshot on/before this day
    case missed     // 2+ days since the most recent snapshot on/before this day
    /// No backup history is known for this day at all (before the earliest
    /// known snapshot, or Time Machine has never produced one) — a neutral
    /// gray cell, never colored red as if a backup was "missed".
    case noData

    var color: Color {
        switch self {
        case .backedUp: return .haloGreen
        case .late: return .haloAmber
        case .missed: return .haloRed
        case .noData: return .haloBorder
        }
    }
}

/// Result of a user-initiated "Back Up Now".
///
/// `tmutil startbackup` needs Full Disk Access on recent macOS; without it the
/// command exits non-zero and explains why. Returning a bare `Bool` threw that
/// explanation away and left the user with a button that silently did nothing.
enum BackupStartResult: Sendable, Equatable {
    case started
    case failed(String)
}

struct BackupHeatmapDay: Identifiable {
    /// The day itself, not a fresh `UUID()`. `heatmap()` is pure and is called
    /// from the view body, so it re-runs on every render — a generated id made
    /// `ForEach` see 30 brand-new cells each time and rebuild all of them
    /// instead of diffing. One day is one cell, so the date is the identity.
    var id: Date { date }
    let date: Date
    let state: BackupDayState
}
