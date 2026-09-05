import Foundation
import AppKit

// MARK: - MemoryTrendTracker  (F-023)
//
// Extends the existing per-process RAM sampling in `ProcessMonitor`
// (`runningAppRAMSamples()`) with a slower, persisted rolling history per app,
// used to flag "possible memory leaks" — apps whose RAM has grown
// monotonically for over an hour without a significant drop.
//
// Runs continuously from app launch (started once from AppState.init, like
// the other Phase-3 managers), independent of whether the Performance view is
// on screen — leak detection needs an uninterrupted sample history, unlike
// TopProcessesSection's view-lifetime timer.
//
// Singleton + @Published, matching the AlertLog/ScanScheduler shape rather
// than an actor, because MemoryTrendsSection reads `histories` directly for
// SwiftUI rendering (no view model in between, same as TopProcessesSection).
@MainActor
final class MemoryTrendTracker: ObservableObject {

    static let shared = MemoryTrendTracker()

    // MARK: - Published state

    @Published private(set) var histories: [AppMemoryHistory] = []

    // MARK: - Tunables
    //
    // Documented in docs/FEATURE_ROADMAP.md's F-023 "As actually built" section —
    // keep both in sync if these change.

    /// Sampling cadence — the spec's "every 30 seconds".
    static let sampleInterval: TimeInterval = 30
    /// Rolling window kept per app — the spec's "2-hour window".
    static let windowSeconds: TimeInterval = 2 * 3600
    /// An unbroken growth streak must span at least this long before the
    /// "Possible memory leak" badge is shown — the spec's ">1 hour". Because a
    /// streak can never be longer than the time Halo has actually observed the
    /// app, this single check also satisfies "don't flag a just-launched app."
    nonisolated static let leakWindowSeconds: TimeInterval = 3600
    /// A drop of more than this fraction from the streak's local peak resets
    /// the growth streak. 15% was chosen as a concrete, sane threshold: it
    /// tolerates normal allocator/cache churn (typically a few percent of
    /// RSS) while still catching a real "user closed some tabs" drop.
    nonisolated static let significantDropFraction: Double = 0.15
    /// If the gap between two consecutive samples exceeds this, the streak
    /// resets rather than counting as continued growth — the machine (or
    /// Halo) was very likely asleep/quit across the gap, so "monotonic
    /// growth" can't honestly be claimed through it. Set to 5x the sample
    /// interval to tolerate a couple of missed ticks without over-resetting.
    nonisolated static let maxSampleGapSeconds: TimeInterval = 5 * 60
    /// Default per-app RAM alert threshold — the spec's "default 2 GB".
    /// User-configurable via UserDefaults["memoryLeakAlertThresholdGB"].
    static let defaultAlertThresholdGB: Double = 2.0
    /// Minimum total growth across a streak before it can be called a leak.
    /// 10% is comfortably outside allocator noise while being far less than any
    /// real leak accumulates over an hour.
    nonisolated static let minimumGrowthFraction: Double = 0.10
    /// The tail of the streak examined for "is it *still* growing". Half an
    /// hour is long enough that a few noisy samples cannot swing the slope,
    /// short enough that a plateau reached 30 minutes ago reads as flat.
    nonisolated static let slopeWindowSeconds: TimeInterval = 30 * 60

    /// Least-squares slope of RAM against time over the samples at or after
    /// `since`, in MB per second. Returns false unless there are enough points
    /// spread over enough time to mean anything — an unknown slope is never
    /// treated as evidence of a leak.
    nonisolated static func hasPositiveSlope(samples: [MemorySample], since: Date) -> Bool {
        let tail = samples.filter { $0.date >= since }
        guard tail.count >= 3 else { return false }

        let t0 = tail[0].date.timeIntervalSince1970
        let xs = tail.map { $0.date.timeIntervalSince1970 - t0 }
        let ys = tail.map(\.ramMB)
        let n = Double(tail.count)

        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }

        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return false }

        return (n * sumXY - sumX * sumY) / denominator > 0
    }

    // MARK: - Private

    // `.shared`, not fresh instances (P0.3). `AlertManager`'s cooldown table is
    // per-instance, so a private copy here would have given F-023's alerts their
    // own cooldown independent of every other kind — the contract is meant to be
    // global. `ProcessMonitor` likewise coalesces sampling across callers, which
    // only works if there is one.
    private let monitor = ProcessMonitor.shared
    private let alertManager = AlertManager.shared
    private var timer: Timer?
    private var didStart = false
    private var persistWorkItem: DispatchWorkItem?

    private static let storageDirectoryName = "Halo"
    private static let storageFileName = "memoryTrendHistory.json"

    /// Opt-in, defaulting to **off**, matching `enableAnalytics` and the
    /// `haloAppUsageTrackingEnabled` toggle its sibling feature uses.
    ///
    /// `memoryTrendHistory.json` is a timestamped record of every application
    /// the user runs. Kept indefinitely it is a usage log: working hours, which
    /// apps are open when, which are never opened at all. That is a materially
    /// different thing to persist than "current RAM per app", and it should be
    /// the user's choice.
    ///
    /// Leak *detection* is unaffected — sampling still runs in memory, so the
    /// feature works this session either way. Only the on-disk history across
    /// restarts is gated.
    static let persistenceEnabledKey = "memoryTrendPersistenceEnabled"

    static var isPersistenceEnabled: Bool {
        UserDefaults.standard.bool(forKey: persistenceEnabledKey)
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Lifecycle

    /// Idempotent — safe to call more than once (e.g. from AppState.init and a
    /// SwiftUI preview) without spinning up duplicate timers.
    func start() {
        guard !didStart else { return }
        didStart = true
        sampleNow()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
    }

    // MARK: - Sampling

    func sampleNow() {
        // The AppKit half is read here on the main actor; only the
        // proc_pidinfo reads go to the actor. See ProcessMonitor.
        let identities = ProcessMonitor.runningAppIdentities()
        Task {
            let samples = await monitor.ramSamples(for: identities)
            await MainActor.run { self.ingest(samples) }
        }
    }

    private func ingest(_ samples: [ProcessMonitor.AppRAMSample]) {
        let now = Date()
        var byID = Dictionary(uniqueKeysWithValues: histories.map { ($0.bundleID, $0) })

        for sample in samples {
            var history = byID[sample.bundleID] ?? AppMemoryHistory(
                bundleID: sample.bundleID, appName: sample.name,
                bundlePath: sample.bundlePath, samples: []
            )
            history.appName = sample.name
            if let path = sample.bundlePath { history.bundlePath = path }
            history.samples.append(MemorySample(date: now, ramMB: sample.ramMB))

            // Trim to the rolling window.
            let cutoff = now.addingTimeInterval(-Self.windowSeconds)
            history.samples.removeAll { $0.date < cutoff }
            byID[sample.bundleID] = history

            // F-023 — per-app RAM threshold alert, wired into the existing AlertManager.
            alertManager.checkAppMemory(appName: sample.name, bundleID: sample.bundleID, ramMB: sample.ramMB)
        }

        // Drop anything with no samples left in the window. Without this,
        // `byID` was seeded from every history ever recorded and only running
        // apps were refreshed — so quitting an app left its record behind
        // forever, aging down to a permanent zero-sample entry. Over weeks that
        // accumulated one entry per app ever launched, and every one of them was
        // re-encoded and written to disk on every tick.
        histories = byID.values
            .filter { !$0.samples.isEmpty }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }

        schedulePersist()
    }

    // MARK: - Leak detection

    /// Walks the samples oldest→newest, tracking a "streak" of monotonic-ish
    /// growth. A streak survives small fluctuations but resets on:
    ///   (a) a >15% drop from the streak's local peak (`significantDropFraction`), or
    ///   (b) an observation gap longer than `maxSampleGapSeconds`.
    /// "Possible leak" fires only once the surviving streak has lasted more
    /// than `leakWindowSeconds` of real, densely-sampled data — never a guess
    /// from a short or gappy history.
    nonisolated func leakStatus(for history: AppMemoryHistory) -> MemoryLeakStatus {
        let samples = history.samples.sorted { $0.date < $1.date }
        guard let first = samples.first, let latest = samples.last else { return .empty }

        var streakStartDate = first.date
        var streakStartRAM = first.ramMB
        var streakPeak = first.ramMB
        var previousDate = first.date

        for sample in samples.dropFirst() {
            let gap = sample.date.timeIntervalSince(previousDate)
            previousDate = sample.date

            if gap > Self.maxSampleGapSeconds {
                // Observation gap — can't vouch for monotonic growth through it.
                streakStartDate = sample.date
                streakStartRAM = sample.ramMB
                streakPeak = sample.ramMB
                continue
            }

            if sample.ramMB > streakPeak {
                streakPeak = sample.ramMB
            } else if streakPeak > 0, sample.ramMB < streakPeak * (1 - Self.significantDropFraction) {
                // Significant drop from the local peak — streak resets here.
                streakStartDate = sample.date
                streakStartRAM = sample.ramMB
                streakPeak = sample.ramMB
            }
            // else: minor fluctuation — streak continues, peak unchanged.
        }

        let streakDuration = latest.date.timeIntervalSince(streakStartDate)

        // Growth must be *material*, not merely non-negative.
        //
        // The old rule was `latest.ramMB > streakStartRAM`, which flagged the
        // most ordinary shape there is. Worked example: RAM climbs 1000 -> 1200
        // in ten minutes, settles to 1100, then sits flat at 1100 for nearly two
        // hours. No >15% drop from the 1200 peak, so no reset; 1100 > 1000, so
        // "growth"; duration > 1 h — "Possible memory leak", for an app whose
        // memory has not moved in 110 minutes. That is exactly how a browser or
        // IDE behaves after it finishes allocating at startup, so the typical
        // case was being reported as the defect.
        //
        // Two additional requirements, both of which a real leak passes easily
        // and a plateau fails:
        //   * total growth of at least `minimumGrowthFraction` over the streak, and
        //   * a positive least-squares slope across the final `slopeWindowSeconds`,
        //     so growth has to still be happening now, not just have happened once.
        let grewMaterially = latest.ramMB > streakStartRAM * (1 + Self.minimumGrowthFraction)
        let stillGrowing = Self.hasPositiveSlope(
            samples: samples,
            since: latest.date.addingTimeInterval(-Self.slopeWindowSeconds)
        )
        let isLeak = streakDuration >= Self.leakWindowSeconds && grewMaterially && stillGrowing

        return MemoryLeakStatus(
            isPossibleLeak: isLeak,
            streakStartDate: streakStartDate,
            streakStartRAMMB: streakStartRAM,
            currentRAMMB: latest.ramMB
        )
    }

    // MARK: - Restart

    /// Terminates then relaunches the app at its bundle URL. The confirmation
    /// dialog lives in the view (`MemoryTrendsSection`) per CLAUDE.md's
    /// "disruptive actions require confirmation" rule — by the time this runs
    /// the user has already confirmed.
    /// How long to wait for a polite quit before giving up. Heavy apps (Xcode,
    /// Photoshop, Docker Desktop) routinely need more than a couple of seconds
    /// to shut down cleanly even with nothing unsaved.
    private static let quitPollTimeout: TimeInterval = 20
    /// 1 s, not 0.25 s. Each poll is a full `NSWorkspace.runningApplications`
    /// enumeration on the main thread, and at 0.25 s over a 20 s timeout that is
    /// up to 80 of them to notice an event the user cannot perceive faster than
    /// about a second anyway.
    private static let quitPollInterval: TimeInterval = 1

    /// Politely quits the app and relaunches it **only once it has actually
    /// exited**.
    ///
    /// The previous implementation waited 1.5 s and then called
    /// `forceTerminate()` — SIGKILL — on anything still running. That inverted
    /// the failure mode exactly: `terminate()` is a request, and the apps that
    /// are still alive afterwards are precisely the ones that put up a "save
    /// changes?" sheet. Force-quitting them threw the sheet and the unsaved
    /// document away, at 1.5 s, on a machine where the user had agreed to
    /// "restart this app" and not to "discard my work".
    ///
    /// So there is no force path any more. If the app does not go, Halo says so
    /// and leaves it alone. A real force-quit would need its own confirmation
    /// naming the risk — a timeout is not consent.
    func restart(_ history: AppMemoryHistory, completion: @escaping (RestartOutcome) -> Void = { _ in }) {
        // One restart per app at a time.
        //
        // The confirmation dialog clears `appPendingRestart` as soon as it is
        // dismissed, while the poll runs for up to 20 s with nothing on screen
        // to say so. Tapping Restart again in that window used to send a second
        // `terminate()` and start a second independent chain — two relaunches
        // racing each other, and two alerts.
        guard !restartsInFlight.contains(history.bundleID) else {
            completion(.failed("\(history.appName) is already being restarted."))
            return
        }

        guard let path = history.bundlePath else {
            completion(.failed("Halo doesn't know where this app is installed."))
            return
        }
        let url = URL(fileURLWithPath: path)
        let bundleID = history.bundleID

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            completion(.failed("\(history.appName) doesn't appear to be running."))
            return
        }

        restartsInFlight.insert(bundleID)
        runningApp.terminate()
        pollForExit(bundleID: bundleID, appName: history.appName, url: url,
                    deadline: Date().addingTimeInterval(Self.quitPollTimeout)) { [weak self] outcome in
            self?.restartsInFlight.remove(bundleID)
            completion(outcome)
        }
    }

    /// Bundle IDs with a restart chain currently polling.
    private var restartsInFlight: Set<String> = []

    private func pollForExit(
        bundleID: String,
        appName: String,
        url: URL,
        deadline: Date,
        completion: @escaping (RestartOutcome) -> Void
    ) {
        let stillRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }

        if !stillRunning {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async {
                    completion(error == nil ? .restarted : .failed("\(appName) quit, but Halo couldn't relaunch it."))
                }
            }
            return
        }

        guard Date() < deadline else {
            // Deliberately does NOT escalate. See restart(_:).
            completion(.didNotQuit("\(appName) didn't quit — it may have unsaved changes waiting for you."))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitPollInterval) { [weak self] in
            self?.pollForExit(bundleID: bundleID, appName: appName, url: url,
                              deadline: deadline, completion: completion)
        }
    }

    // MARK: - Persistence
    //
    // JSON file in Application Support (not UserDefaults) — a 2-hour/30 s
    // window is ~240 samples per app, and with several apps tracked at once
    // the encoded payload is comfortably into the tens of KB, which is fine
    // for a file but is exactly the kind of growth UserDefaults handles
    // poorly (it's backed by a single plist loaded entirely into memory).

    /// Resolved once. This used to be a computed property that called
    /// `createDirectory` on every read, and it was read from `persistToDisk()`
    /// every 30 seconds — a no-op syscall on the main thread twice a minute,
    /// forever.
    private static let storageURL: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(storageDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(storageFileName)
    }()

    /// Coalesces writes and gets the encode + write off the main actor.
    ///
    /// Encoding every history to JSON and writing it synchronously on the main
    /// thread twice a minute is work the UI should never be doing. Losing at
    /// most one 30-second bucket to an unclean exit is immaterial for a
    /// two-hour rolling window.
    private func schedulePersist() {
        persistWorkItem?.cancel()
        guard Self.isPersistenceEnabled else { return }
        let snapshot = histories
        let item = DispatchWorkItem {
            guard let url = Self.storageURL,
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        persistWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: item)
    }

    /// Writes immediately, for app termination.
    func flushToDisk() {
        persistWorkItem?.cancel()
        guard Self.isPersistenceEnabled else { return }
        guard let url = Self.storageURL, let data = try? JSONEncoder().encode(histories) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes the on-disk history and clears what is held in memory.
    /// Exposed in Settings beside the toggle, matching the clipboard module's
    /// "Clear All History Now".
    func clearHistory() {
        persistWorkItem?.cancel()
        histories = []
        if let url = Self.storageURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func loadFromDisk() {
        // Nothing on disk is read back while the toggle is off, and anything
        // written before it was turned off is removed rather than left behind.
        guard Self.isPersistenceEnabled else {
            if let url = Self.storageURL { try? FileManager.default.removeItem(at: url) }
            return
        }
        guard let url = Self.storageURL,
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([AppMemoryHistory].self, from: data) else { return }
        // Drop anything already outside the rolling window at load time (e.g.
        // Halo was quit for days) so a stale history can't fake a leak streak.
        let cutoff = Date().addingTimeInterval(-Self.windowSeconds)
        histories = saved.map { h in
            var h = h
            h.samples.removeAll { $0.date < cutoff }
            return h
        }
    }
}
