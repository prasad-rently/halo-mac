import Foundation
import SwiftUI

// MARK: - Download File Model

struct DownloadFile: Identifiable, Equatable {
    let id: UUID = UUID()
    let url: URL
    let name: String
    let sizeBytes: Int64
    let createdDate: Date
    let modifiedDate: Date
    let fileType: DownloadFileType
    var isSelected: Bool = false

    var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    var displayPath: String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var ageGroup: DownloadAgeGroup {
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(modifiedDate) { return .today }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
           modifiedDate >= weekAgo { return .thisWeek }
        if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
           modifiedDate >= monthAgo { return .thisMonth }
        if let threeMonthsAgo = calendar.date(byAdding: .month, value: -3, to: now),
           modifiedDate >= threeMonthsAgo { return .older }
        return .stale
    }

    /// Whether this is a .dmg/.pkg installer whose app is already installed.
    var isSafeToRemoveInstaller: Bool = false
}

// MARK: - Download File Type

enum DownloadFileType: String, CaseIterable, Identifiable {
    case image     = "Images"
    case video     = "Videos"
    case audio     = "Audio"
    case document  = "Documents"
    case archive   = "Archives"
    case installer = "Installers"
    case code      = "Code"
    case other     = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .image:     return "photo.fill"
        case .video:     return "film.fill"
        case .audio:     return "music.note"
        case .document:  return "doc.text.fill"
        case .archive:   return "doc.zipper"
        case .installer: return "shippingbox.fill"
        case .code:      return "chevron.left.forwardslash.chevron.right"
        case .other:     return "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .image:     return Color(hex: "#f59e0b")
        case .video:     return Color(hex: "#ec4899")
        case .audio:     return Color(hex: "#8b5cf6")
        case .document:  return Color(hex: "#4f7cff")
        case .archive:   return Color(hex: "#f97316")
        case .installer: return Color(hex: "#22d97a")
        case .code:      return Color(hex: "#00d4e8")
        case .other:     return Color(hex: "#6b7280")
        }
    }

    static func detect(from url: URL) -> DownloadFileType {
        let ext = url.pathExtension.lowercased()
        switch ext {
        // Images
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "svg",
             "heic", "heif", "ico", "raw", "cr2", "nef", "arw":
            return .image
        // Videos
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "3gp":
            return .video
        // Audio
        case "mp3", "wav", "aac", "flac", "ogg", "wma", "m4a", "aiff", "alac":
            return .audio
        // Documents
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf",
             "csv", "pages", "numbers", "key", "epub", "odt", "ods":
            return .document
        // Archives
        case "zip", "tar", "gz", "bz2", "7z", "rar", "xz", "tgz", "tbz2":
            return .archive
        // Installers
        case "dmg", "pkg", "app", "iso", "msi", "deb", "rpm":
            return .installer
        // Code
        case "swift", "py", "js", "ts", "jsx", "tsx", "java", "kt", "go", "rs",
             "rb", "php", "c", "cpp", "h", "m", "cs", "html", "css", "scss",
             "json", "yaml", "yml", "xml", "sh", "bash", "zsh", "sql",
             "r", "lua", "pl", "ex", "exs", "hs", "ml", "scala":
            return .code
        default:
            return .other
        }
    }
}

// MARK: - Download Age Group

enum DownloadAgeGroup: String, CaseIterable, Identifiable {
    case today     = "Today"
    case thisWeek  = "This Week"
    case thisMonth = "This Month"
    case older     = "Older"
    case stale     = "Stale (90+ days)"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .today:     return Color(hex: "#22d97a")
        case .thisWeek:  return Color(hex: "#4f7cff")
        case .thisMonth: return Color(hex: "#f5a623")
        case .older:     return Color(hex: "#f97316")
        case .stale:     return Color(hex: "#ff4d6a")
        }
    }

    var icon: String {
        switch self {
        case .today:     return "clock.fill"
        case .thisWeek:  return "calendar"
        case .thisMonth: return "calendar.badge.clock"
        case .older:     return "calendar.badge.minus"
        case .stale:     return "calendar.badge.exclamationmark"
        }
    }
}

// MARK: - Group Mode

enum DownloadGroupMode: String, CaseIterable {
    case byAge  = "By Age"
    case byType = "By Type"
}

// MARK: - DownloadsViewModel

@MainActor
final class DownloadsViewModel: ObservableObject {

    @Published var files: [DownloadFile] = []
    @Published var isScanning = false
    @Published var hasScanned = false
    @Published var groupMode: DownloadGroupMode = .byAge
    @Published var searchText = ""

    // Cleanup state
    @Published var showCleanConfirm = false
    @Published var showOrganizeConfirm = false
    /// File pending single-item trash — set on tap, cleared on confirm/cancel.
    /// Gates `trashFile` behind a confirmation (TC-SAFE-02).
    @Published var pendingTrash: DownloadFile?
    @Published var statusMessage: String?

    // MARK: - Computed

    var totalSize: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    var totalSizeFormatted: String { ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file) }
    var fileCount: Int { files.count }

    var staleFiles: [DownloadFile] {
        files.filter { $0.ageGroup == .stale }
    }

    var staleTotalBytes: Int64 { staleFiles.reduce(0) { $0 + $1.sizeBytes } }
    var staleSizeFormatted: String { ByteCountFormatter.string(fromByteCount: staleTotalBytes, countStyle: .file) }

    var safeInstallers: [DownloadFile] {
        files.filter { $0.isSafeToRemoveInstaller }
    }

    var filteredFiles: [DownloadFile] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return files }
        return files.filter {
            $0.name.lowercased().contains(trimmed) ||
            $0.fileType.rawValue.lowercased().contains(trimmed)
        }
    }

    // MARK: - Grouped Data

    func groupedByAge() -> [(DownloadAgeGroup, [DownloadFile])] {
        let filtered = filteredFiles
        return DownloadAgeGroup.allCases.compactMap { group in
            let items = filtered.filter { $0.ageGroup == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    func groupedByType() -> [(DownloadFileType, [DownloadFile])] {
        let filtered = filteredFiles
        return DownloadFileType.allCases.compactMap { type in
            let items = filtered.filter { $0.fileType == type }
            return items.isEmpty ? nil : (type, items.sorted { $0.sizeBytes > $1.sizeBytes })
        }
    }

    /// Size per age group for the breakdown bar.
    func ageBreakdown() -> [(DownloadAgeGroup, Int64)] {
        DownloadAgeGroup.allCases.map { group in
            let total = files.filter { $0.ageGroup == group }.reduce(0 as Int64) { $0 + $1.sizeBytes }
            return (group, total)
        }
        .filter { $0.1 > 0 }
    }

    /// Size per type for the breakdown bar.
    func typeBreakdown() -> [(DownloadFileType, Int64)] {
        DownloadFileType.allCases.map { type in
            let total = files.filter { $0.fileType == type }.reduce(0 as Int64) { $0 + $1.sizeBytes }
            return (type, total)
        }
        .filter { $0.1 > 0 }
    }

    // MARK: - Scan

    func scan() async {
        isScanning = true

        let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")

        guard FileManager.default.fileExists(atPath: downloadsURL.path) else {
            isScanning = false
            hasScanned = true
            return
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey]

        var scanned: [DownloadFile] = []
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: downloadsURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])

            for url in contents {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      !(values.isDirectory ?? false) else { continue }

                let size = Int64(values.fileSize ?? 0)
                let created = values.creationDate ?? Date.distantPast
                let modified = values.contentModificationDate ?? created

                scanned.append(DownloadFile(
                    url: url,
                    name: url.lastPathComponent,
                    sizeBytes: size,
                    createdDate: created,
                    modifiedDate: modified,
                    fileType: DownloadFileType.detect(from: url)
                ))
            }
        } catch {
            // silently fail — empty list
        }

        // Cross-reference installers with installed apps
        let appScanner = AppScanner()
        let installedApps = await appScanner.scanApps()
        let installedNames = Set(installedApps.map { $0.name.lowercased() })

        for i in scanned.indices {
            if scanned[i].fileType == .installer {
                let baseName = scanned[i].url.deletingPathExtension().lastPathComponent
                    .lowercased()
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")

                // Check if any installed app name is contained in the installer filename
                scanned[i].isSafeToRemoveInstaller = installedNames.contains(where: { appName in
                    baseName.contains(appName) || appName.contains(baseName)
                })
            }
        }

        files = scanned.sorted { $0.modifiedDate > $1.modifiedDate }
        isScanning = false
        hasScanned = true
    }

    // MARK: - Cleanup Actions

    func cleanStaleFiles() async {
        let targets = staleFiles
        guard !targets.isEmpty else { return }

        var freedBytes: Int64 = 0
        var removedCount = 0

        for file in targets {
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                freedBytes += file.sizeBytes
                removedCount += 1
            } catch {
                // skip failures silently
            }
        }

        files.removeAll { f in targets.contains(where: { $0.url == f.url }) }
        let freedFormatted = ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)
        statusMessage = "Moved \(removedCount) stale files to Trash (\(freedFormatted) freed)"
        clearStatusAfterDelay()
    }

    func cleanSafeInstallers() async {
        let targets = safeInstallers
        guard !targets.isEmpty else { return }

        var freedBytes: Int64 = 0
        var removedCount = 0

        for file in targets {
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                freedBytes += file.sizeBytes
                removedCount += 1
            } catch {
                // skip
            }
        }

        files.removeAll { f in targets.contains(where: { $0.url == f.url }) }
        let freedFormatted = ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)
        statusMessage = "Moved \(removedCount) installers to Trash (\(freedFormatted) freed)"
        clearStatusAfterDelay()
    }

    func organizeIntoSubfolders() async {
        let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")

        var movedCount = 0

        for file in files {
            let subfolder = file.fileType.rawValue  // "Images", "Documents", etc.
            let destDir = downloadsURL.appendingPathComponent(subfolder)

            // Create subfolder if needed
            if !FileManager.default.fileExists(atPath: destDir.path) {
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            }

            let destFile = destDir.appendingPathComponent(file.name)
            guard !FileManager.default.fileExists(atPath: destFile.path) else { continue }

            do {
                try FileManager.default.moveItem(at: file.url, to: destFile)
                movedCount += 1
            } catch {
                // skip
            }
        }

        statusMessage = "Organized \(movedCount) files into subfolders"
        clearStatusAfterDelay()

        // Re-scan to reflect new state
        await scan()
    }

    func revealInFinder(_ file: DownloadFile) {
        NSWorkspace.shared.selectFile(file.url.path, inFileViewerRootedAtPath: "")
    }

    func trashFile(_ file: DownloadFile) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            files.removeAll { $0.url == file.url }
            statusMessage = "Moved \(file.name) to Trash"
            clearStatusAfterDelay()
        } catch {
            statusMessage = "Failed to trash \(file.name)"
            clearStatusAfterDelay()
        }
    }

    // MARK: - Private

    private func clearStatusAfterDelay() {
        let msg = statusMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.statusMessage == msg { self?.statusMessage = nil }
        }
    }
}
