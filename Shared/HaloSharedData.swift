import Foundation

// Written by the main app every 2s; read by the widget timeline provider.
// Both targets must be in the "group.com.halo.mac" App Group for production.
// In debug builds (no provisioning profile) the suite falls back to
// UserDefaults.standard so macOS never prompts for App Group access.
struct HaloWidgetData: Codable {
    var cpuUsage: Double        // 0.0–1.0
    var ramUsage: Double        // 0.0–1.0
    var ramUsedGB: Double
    var ramTotalGB: Double
    var networkUpMBps: Double
    var networkDownMBps: Double
    var clipboardPreviews: [String]  // up to 5 recent text snippets

    static let suiteName = "group.com.halo.mac"
    static let defaultsKey = "haloWidgetData"

    /// Resolves to the App Group suite when available, standard defaults otherwise.
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? UserDefaults.standard
    }

    static func load() -> HaloWidgetData {
        guard
            let data    = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(HaloWidgetData.self, from: data)
        else {
            return HaloWidgetData(cpuUsage: 0, ramUsage: 0, ramUsedGB: 0,
                                  ramTotalGB: 8, networkUpMBps: 0,
                                  networkDownMBps: 0, clipboardPreviews: [])
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults.set(data, forKey: Self.defaultsKey)
    }
}
