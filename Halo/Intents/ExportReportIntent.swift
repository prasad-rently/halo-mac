import AppIntents
import Foundation

struct ExportReportIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Health Report"
    static var description = IntentDescription("Generates a PDF health report of your Mac and returns it as a file.")

    static var parameterSummary: some ParameterSummary {
        Summary("Export Mac health report as PDF")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let appState = await MainActor.run(body: { AppState.shared }) else {
            throw IntentError.appNotRunning
        }

        let snapshot = await MainActor.run { ReportSnapshot.capture(from: appState) }
        let pdf = ReportGenerator.shared.generate(snapshot: snapshot)

        guard let data = pdf.dataRepresentation() else {
            throw IntentError.reportGenerationFailed
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "Halo-Report-\(formatter.string(from: Date())).pdf"

        return .result(value: IntentFile(data: data, filename: filename, type: .pdf))
    }
}

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appNotRunning
    case reportGenerationFailed
    case actionNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotRunning:          return "Halo is not running. Please open the app first."
        case .reportGenerationFailed: return "Failed to generate the health report."
        case .actionNotFound:         return "The specified action was not found."
        }
    }
}
