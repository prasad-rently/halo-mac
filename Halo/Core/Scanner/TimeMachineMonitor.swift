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

        let destination = Self.parseDestinationInfo(destInfo)
        let name = destination.name
        let mountPoint = destination.mountPoint

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
            destinationURL: destination.url,
            isNetworkDestination: destination.isNetwork,
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
    /// On recent macOS `tmutil startbackup` requires the caller to hold Full
    /// Disk Access. Without it the command exits non-zero and prints the reason
    /// to stderr — so this merges stderr and hands the text back rather than
    /// collapsing every distinct failure into a silent `false`.
    @discardableResult
    func startBackupNow() async -> BackupStartResult {
        let result = runWithExitCode("/usr/bin/tmutil", ["startbackup"], mergeStderr: true)
        guard result.exitCode == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == -1 {
                return .failed("Halo could not launch tmutil. In a sandboxed build this is blocked outright.")
            }
            return .failed(message.isEmpty
                           ? "tmutil exited with code \(result.exitCode)."
                           : message)
        }
        return .started
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
    ///
    /// A **network** destination (Time Capsule, NAS, any SMB/AFP share) reports
    /// `Kind : Network` and a `URL`, and has no `Mount Point` at all until its
    /// sparsebundle happens to be mounted. Reading only `Mount Point` therefore
    /// made every network destination look permanently disconnected with no
    /// capacity — a healthy, currently-backing-up Time Capsule shown as
    /// unreachable. The `URL` is parsed so that case can be told apart.
    ///
    /// Note the `URL` value itself contains `://`, so the split must be on the
    /// *first* colon only — which `firstIndex(of:)` already does.
    static func parseDestinationInfo(_ output: String) -> DestinationInfo {
        var info = DestinationInfo()
        for rawLine in output.split(separator: "\n") {
            guard let colonIndex = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[rawLine.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = rawLine[rawLine.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "Name":        if info.name == nil { info.name = value }
            case "Mount Point": if info.mountPoint == nil { info.mountPoint = value }
            case "URL":         if info.url == nil { info.url = value }
            case "Kind":        if info.kind == nil { info.kind = value }
            default: break
            }
        }
        return info
    }

    struct DestinationInfo {
        var name: String?
        var mountPoint: String?
        var url: String?
        var kind: String?

        /// `tmutil` reports "Network" for Time Capsule / NAS destinations. The
        /// presence of a `URL` with no `Mount Point` means the same thing, and
        /// is checked as a fallback in case the `Kind` wording ever shifts.
        var isNetwork: Bool {
            if let kind { return kind.caseInsensitiveCompare("Network") == .orderedSame }
            return url != nil && mountPoint == nil
        }
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

    /// Runs a tool and returns its output and exit status.
    ///
    /// The ordering here is load-bearing. Draining the pipe **before**
    /// `waitUntilExit()` is what keeps this from deadlocking: a pipe holds
    /// roughly 64 KB, and once the child fills it the child blocks on `write`
    /// while the parent blocks in `waitUntilExit`, and neither ever moves.
    /// `tmutil listbackups` is exactly the command that reaches that ceiling —
    /// it prints one absolute snapshot path per line at ~70–90 bytes, so a
    /// destination with a year of thinned history is comfortably past 64 KB.
    ///
    /// `readDataToEndOfFile()` returns when the child closes its end of the
    /// pipe, which happens when it exits, so this both collects the output and
    /// waits for completion — `waitUntilExit()` afterwards only reaps the
    /// status.
    ///
    /// stderr is the second way to deadlock, and the subtler one: an
    /// unattached `Pipe()` that nobody reads fills and blocks the child just
    /// the same. It goes to `nullDevice` unless the caller actually wants the
    /// diagnostics, in which case it is merged into the single stdout pipe
    /// (plain `2>&1`) so there is still only one buffer and one reader.
    private func runWithExitCode(
        _ path: String,
        _ args: [String],
        mergeStderr: Bool = false
    ) -> (output: String, exitCode: Int32) {
        let result = ShellReader.run(path, args)

        // Denied by the sandbox, or the tool is missing. Either way there is no
        // output and no exit status — callers treat -1 as "we were not able to
        // ask", which is not the same as "nothing found".
        guard result.launchFailure == nil else { return ("", -1) }

        // A child that overran its ceiling was killed, so its output is partial
        // and its status meaningless. Report it as the same "could not ask"
        // state rather than letting a truncated `tmutil` listing read as a
        // complete one.
        guard !result.didTimeOut else { return ("", -1) }

        // `mergeStderr` used to mean literal `2>&1` into one pipe. ShellReader
        // drains both concurrently, so there is no buffer to overflow and the
        // streams can simply be concatenated when the caller wants diagnostics.
        let output = mergeStderr
            ? result.standardOutput + result.standardError
            : result.standardOutput
        return (output, result.exitCode)
    }
}
