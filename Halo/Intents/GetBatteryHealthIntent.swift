import AppIntents
import Foundation

struct GetBatteryHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Battery Health"
    static var description = IntentDescription("Returns battery status including charge level, health percentage, and cycle count.")

    static var parameterSummary: some ParameterSummary {
        Summary("Get battery health info")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let info = await MainActor.run { () -> (Int, Double, Int, Bool) in
            guard let s = AppState.shared else { return (0, 0, 0, false) }
            return (s.batteryPercent, s.batteryHealth, s.batteryCycles, s.batteryIsCharging)
        }
        let healthPct = Int(info.1 * 100)
        let charging = info.3 ? " (charging)" : ""
        let summary = "Battery: \(info.0)%\(charging), Health: \(healthPct)%, Cycles: \(info.2)"
        return .result(value: summary)
    }
}
