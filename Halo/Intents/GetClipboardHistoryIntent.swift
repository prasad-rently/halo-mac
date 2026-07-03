import AppIntents
import Foundation

struct GetClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Clipboard History"
    static var description = IntentDescription("Returns the most recent clipboard text items from Halo's history.")

    @Parameter(title: "Number of items", default: 5, inclusiveRange: (1, 10))
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get last \(\.$count) clipboard items")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let items = await MainActor.run { () -> [String] in
            guard let s = AppState.shared else { return [] }
            return s.clipboardItems.prefix(count).compactMap { item -> String? in
                switch item.content {
                case .text(let t):    return t
                case .code(let c, _): return c
                case .url(let u):     return u.absoluteString
                case .color(let h):   return h
                case .image:          return nil
                }
            }
        }
        return .result(value: items)
    }
}
