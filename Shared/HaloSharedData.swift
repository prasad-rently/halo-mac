import Foundation

// Written by the main app every 2s; read by the widget timeline provider.
// Both targets must be in the "group.com.halo.mac" App Group.
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

    static func load() -> HaloWidgetData {
        guard
            let defaults = UserDefaults(suiteName: suiteName),
            let data = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(HaloWidgetData.self, from: data)
        else {
            return HaloWidgetData(cpuUsage: 0, ramUsage: 0, ramUsedGB: 0,
                                  ramTotalGB: 8, networkUpMBps: 0,
                                  networkDownMBps: 0, clipboardPreviews: [])
        }
        return decoded
    }

    func save() {
        guard
            let defaults = UserDefaults(suiteName: Self.suiteName),
            let data = try? JSONEncoder().encode(self)
        else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
