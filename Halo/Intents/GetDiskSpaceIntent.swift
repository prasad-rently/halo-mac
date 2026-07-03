import AppIntents
import Foundation

struct GetDiskSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Disk Space"
    static var description = IntentDescription("Returns available and total disk space on this Mac.")

    static var parameterSummary: some ParameterSummary {
        Summary("Get disk space info")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let info = await MainActor.run { () -> (Double, Double) in
            guard let s = AppState.shared else { return (0, 0) }
            return (s.diskFreeGB, s.diskTotalGB)
        }
        let free = String(format: "%.1f", info.0)
        let total = String(format: "%.1f", info.1)
        let usedPct = info.1 > 0 ? Int(((info.1 - info.0) / info.1) * 100) : 0
        return .result(value: "\(free) GB free of \(total) GB (\(usedPct)% used)")
    }
}
