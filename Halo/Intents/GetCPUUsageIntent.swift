import AppIntents
import Foundation

struct GetCPUUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Get CPU Usage"
    static var description = IntentDescription("Returns the current CPU usage percentage from Halo.")

    static var parameterSummary: some ParameterSummary {
        Summary("Get CPU usage percentage")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        let usage = await MainActor.run { AppState.shared?.cpuUsage ?? 0 }
        let rounded = (usage * 1000).rounded() / 10
        return .result(value: rounded)
    }
}
