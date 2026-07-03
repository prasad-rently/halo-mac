import AppIntents
import Foundation

struct RunSmartScanIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Smart Scan"
    static var description = IntentDescription("Runs a full Smart Scan of your Mac and returns a summary of findings.")

    static var parameterSummary: some ParameterSummary {
        Summary("Run a Mac health scan")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let appState = await MainActor.run(body: { AppState.shared }) else {
            return .result(value: "Halo is not running. Please open the app first.")
        }

        await appState.runSmartScan()

        let summary = await MainActor.run { () -> String in
            let score = appState.systemHealthScore
            if let result = appState.smartScanResult {
                let bytes = result.totalBytesFormatted
                let threats = result.threatsFound
                return "Health score: \(score)/100. Found \(bytes) cleanable data and \(threats) threat(s)."
            }
            return "Health score: \(score)/100. Scan complete — your Mac looks clean."
        }
        return .result(value: summary)
    }
}
