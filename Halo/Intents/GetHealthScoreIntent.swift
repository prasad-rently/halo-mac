import AppIntents

struct GetHealthScoreIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Health Score"
    static var description = IntentDescription("Returns the current Mac health score (0–100) from Halo.")

    static var parameterSummary: some ParameterSummary {
        Summary("Get Mac health score")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let score = await MainActor.run { AppState.shared?.systemHealthScore ?? 0 }
        return .result(value: score)
    }
}
