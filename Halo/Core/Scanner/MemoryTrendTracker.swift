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
    static let leakWindowSeconds: TimeInterval = 3600
    /// A drop of more than this fraction from the streak's local peak resets
    /// the growth streak. 15% was chosen as a concrete, sane threshold: it
    /// tolerates normal allocator/cache churn (typically a few percent of
    /// RSS) while still catching a real "user closed some tabs" drop.
    static let significantDropFraction: Double = 0.15
    /// If the gap between two consecutive samples exceeds this, the streak
    /// resets rather than counting as continued growth — the machine (or
    /// Halo) was very likely asleep/quit across the gap, so "monotonic
    /// growth" can't honestly be claimed through it. Set to 5x the sample
    /// interval to tolerate a couple of missed ticks without over-resetting.
    static let maxSampleGapSeconds: TimeInterval = 5 * 60
    /// Default per-app RAM alert threshold — the spec's "default 2 GB".
    /// User-configurable via UserDefaults["memoryLeakAlertThresholdGB"].
    static let defaultAlertThresholdGB: Double = 2.0

    // MARK: - Private

    private let monitor = ProcessMonitor()
    private let alertManager = AlertManager()
    private var timer: Timer?
    private var didStart = false

    private static let storageDirectoryName = "Halo"
    private static let storageFileName = "memoryTrendHistory.json"

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
        Task {
            let samples = await monitor.runningAppRAMSamples()
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

        histories = byID.values.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        persistToDisk()
    }

    // MARK: - Leak detection

    /// Walks the samples oldest→newest, tracking a "streak" of monotonic-ish
    /// growth. A streak survives small fluctuations but resets on:
    ///   (a) a >15% drop from the streak's local peak (`significantDropFraction`), or
    ///   (b) an observation gap longer than `maxSampleGapSeconds`.
    /// "Possible leak" fires only once the surviving streak has lasted more
    /// than `leakWindowSeconds` of real, densely-sampled data — never a guess
    /// from a short or gappy history.
    func leakStatus(for history: AppMemoryHistory) -> MemoryLeakStatus {
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
        let isLeak = streakDuration >= Self.leakWindowSeconds && latest.ramMB > streakStartRAM

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
    func restart(_ history: AppMemoryHistory) {
        guard let path = history.bundlePath else { return }
        let url = URL(fileURLWithPath: path)
        let bundleID = history.bundleID

        let runningApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        runningApp?.terminate()

        // terminate() is asynchronous — give the app a moment to fully exit
        // before relaunching, force-quitting as a fallback if it's still around.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let stillRunning = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                stillRunning.forceTerminate()
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    // MARK: - Persistence
    //
    // JSON file in Application Support (not UserDefaults) — a 2-hour/30 s
    // window is ~240 samples per app, and with several apps tracked at once
    // the encoded payload is comfortably into the tens of KB, which is fine
    // for a file but is exactly the kind of growth UserDefaults handles
    // poorly (it's backed by a single plist loaded entirely into memory).

    private var storageURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(Self.storageDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.storageFileName)
    }

    private func persistToDisk() {
        guard let url = storageURL, let data = try? JSONEncoder().encode(histories) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadFromDisk() {
        guard let url = storageURL,
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
