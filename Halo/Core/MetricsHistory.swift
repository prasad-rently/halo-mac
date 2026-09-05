import Foundation

// MARK: - MetricsHistory (F-029)
//
// Lightweight rolling store of hourly system snapshots, used for:
//   • the 7-day health-score sparkline card on the Dashboard (HealthTrendCard)
//   • the Weekly Digest's health trend + disk-free delta + top-RAM-apps
//     sections (WeeklyDigestGenerator)
//
// Sampled by AppState's DEDICATED hourly timer — deliberately NOT hooked into
// the existing 2-second metricsTimer. Hooking into the fast tick would produce
// ~1,800x too much data for a week-long history (the same class of mistake
// the widget pipeline avoids by reloading timelines every 60 s instead of
// every 2 s — see CLAUDE.md's Widget Pipeline section).
//
// Persisted to UserDefaults as JSON, capped at 7 days of hourly samples (168).

@MainActor
final class MetricsHistory: ObservableObject {

    static let shared = MetricsHistory()
    private init() { load() }

    @Published private(set) var samples: [MetricsSample] = []

    private static let defaultsKey = "haloMetricsHistory"
    /// 7 days × 24 samples/day at the 1-sample/hour cadence.
    private static let maxSamples = 24 * 7

    // MARK: - Mutations

    func record(healthScore: Int, diskFreeGB: Double, topRAMProcesses: [ProcessRAMSample]) {
        let sample = MetricsSample(healthScore: healthScore, diskFreeGB: diskFreeGB, topRAMProcesses: topRAMProcesses)
        samples.append(sample)
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
        persist()
    }

    // MARK: - Queries

    /// Samples from the last `days` days (default 7), oldest first.
    func recent(days: Int = 7) -> [MetricsSample] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        return samples.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(samples) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([MetricsSample].self, from: data) else { return }
        samples = saved
    }
}
