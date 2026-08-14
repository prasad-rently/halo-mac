import Foundation

// MARK: - Time Machine Backup Health Monitor (F-022)
//
// Read-only checks of Time Machine status via the public `tmutil` CLI — no
// entitlements, no elevation. The single write action ("Back Up Now") is a
// normal, user-initiated `tmutil startbackup`, identical to clicking "Back
// Up Now" from the Time Machine menu bar icon.
//
// Honesty constraint: if Time Machine has never been configured on this Mac,
// `status()` returns `.notConfigured` — the UI must show an explicit empty
// state, never a fabricated "healthy" card or an empty heatmap pretending
// backups exist.
actor TimeMachineMonitor {

    func status() async -> TimeMachineStatus {
        let destInfo = run("/usr/bin/tmutil", ["destinationinfo"])
        guard !destInfo.contains("No destinations configured") else {
            return .notConfigured
        }

        let (name, mountPoint) = parseDestinationInfo(destInfo)

        let statusOutput = run("/usr/bin/tmutil", ["status"])
        let isRunning = statusOutput.contains("Running = 1")

        var isReachable = false
        var availableBytes: Int64?
        var totalBytes: Int64?

        // Available/total space comes straight from the mounted volume rather
        // than from `tmutil` (which doesn't expose capacity) — real numbers,
        // not guessed ones, and they naturally read as "unavailable" (nil)
        // when the destination drive is disconnected.
        if let mountPoint, FileManager.default.fileExists(atPath: mountPoint) {
            isReachable = true
            let url = URL(fileURLWithPath: mountPoint)
            if let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ]) {
                availableBytes = values.volumeAvailableCapacityForImportantUsage
                if let total = values.volumeTotalCapacity {
                    totalBytes = Int64(total)
                }
            }
        }

        let backupDates = parseListBackups(run("/usr/bin/tmutil", ["listbackups"]))

        // `latestbackup` fails outright (empty stdout) when the destination is
        // unreachable — fall back to the newest date from `listbackups` (which
        // reads local snapshot metadata and can succeed even then).
        let latestOutput = run("/usr/bin/tmutil", ["latestbackup"])
        let lastBackupDate = parseBackupPath(latestOutput) ?? backupDates.max()

        return TimeMachineStatus(
            isConfigured: true,
            destinationName: name,
            mountPoint: mountPoint,
            isReachable: isReachable,
            availableBytes: availableBytes,
            totalBytes: totalBytes,
            lastBackupDate: lastBackupDate,
            isBackupRunning: isRunning,
            backupDates: backupDates
        )
    }

    /// Kicks off a normal Time Machine backup — identical to "Back Up Now" in
    /// the menu bar icon. Returns `false` only when the command genuinely
    /// failed to launch or exited non-zero (e.g. no destination configured);
    /// success just means the backup was *accepted*, not that it finished —
    /// callers should re-poll `status()` to observe progress/completion.
    @discardableResult
    func startBackupNow() async -> Bool {
        let result = runWithExitCode("/usr/bin/tmutil", ["startbackup"])
        return result.exitCode == 0
    }

    // MARK: - Heatmap

    /// Pure, synchronous derivation of the 30-day GitHub-style heatmap from
    /// known backup dates — no I/O, callable without `await` (mirrors
    /// `SecurityPostureScanner.score(for:)`'s static-on-actor pattern).
    ///
    /// A day is `.noData` (gray) rather than `.missed` (red) whenever Halo has
    /// no real information to judge it by — before the earliest known backup,
    /// or when there's no backup history at all. Never fabricated as "missed".
    static func heatmap(backupDates: [Date], days: Int = 30, referenceDate: Date = Date()) -> [BackupHeatmapDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let backupDays = Set(backupDates.map { calendar.startOfDay(for: $0) })

        guard let earliestBackupDay = backupDays.min() else {
            return (0..<days).reversed().map { offset in
                let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
                return BackupHeatmapDay(date: day, state: .noData)
            }
        }

        var result: [BackupHeatmapDay] = []
        result.reserveCapacity(days)
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }

            if backupDays.contains(day) {
                result.append(BackupHeatmapDay(date: day, state: .backedUp))
                continue
            }
            if day < earliestBackupDay {
                result.append(BackupHeatmapDay(date: day, state: .noData))
                continue
            }
            guard let mostRecent = backupDays.filter({ $0 <= day }).max() else {
                result.append(BackupHeatmapDay(date: day, state: .noData))
                continue
            }
            let gap = calendar.dateComponents([.day], from: mostRecent, to: day).day ?? 0
            result.append(BackupHeatmapDay(date: day, state: gap >= 2 ? .missed : .late))
        }
        return result
    }

    // MARK: - Parsing

    /// `tmutil destinationinfo` prints one or more "Key : Value" blocks
    /// separated by "====" lines. Halo surfaces the primary (first) destination.
    private func parseDestinationInfo(_ output: String) -> (name: String?, mountPoint: String?) {
        var name: String?
        var mountPoint: String?
        for rawLine in output.split(separator: "\n") {
            guard let colonIndex = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[rawLine.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = rawLine[rawLine.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "Name": if name == nil { name = value }
            case "Mount Point": if mountPoint == nil { mountPoint = value }
            default: break
            }
        }
        return (name, mountPoint)
    }

    /// `tmutil listbackups` prints one absolute snapshot path per line, e.g.
    /// `/Volumes/Backup/Backups.backupdb/MacBook-Pro/2026-08-14-120000`.
    /// Lines that don't parse (including this machine's real-world failure
    /// output like "No machine directory found for host.") are silently
    /// skipped rather than crashing the scan.
    private func parseListBackups(_ output: String) -> [Date] {
        output.split(separator: "\n").compactMap { parseBackupPath(String($0)) }
    }

    /// Parses the trailing `YYYY-MM-DD-HHMMSS` path component shared by both
    /// `tmutil latestbackup` and `tmutil listbackups`.
    private func parseBackupPath(_ path: String) -> Date? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(separator: "/").last else { return nil }
        return Self.backupPathFormatter.date(from: String(last))
    }

    private static let backupPathFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // MARK: - Process helpers

    private func run(_ path: String, _ args: [String]) -> String {
        runWithExitCode(path, args).output
    }

    private func runWithExitCode(_ path: String, _ args: [String]) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("", -1)
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
}
