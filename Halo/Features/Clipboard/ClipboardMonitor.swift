import Foundation
import AppKit

// MARK: - Clipboard Monitor
// Polls NSPasteboard every 0.8 seconds for changes.
// In production, wraps detection in a background NSTimer via RunLoop.

@MainActor
final class ClipboardMonitor: ObservableObject {
    @Published var latestItem: ClipboardItem? = nil

    var suppressNext = false
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let onNewItem: (ClipboardItem) -> Void

    init(onNewItem: @escaping (ClipboardItem) -> Void) {
        self.onNewItem = onNewItem
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if suppressNext { suppressNext = false; return }

        guard let item = extractItem(from: pb) else { return }
        latestItem = item
        onNewItem(item)
    }

    // MARK: - Content Extraction

    private func extractItem(from pb: NSPasteboard) -> ClipboardItem? {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // Image
        if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
            let meta = imageMetadata(from: data)
            return ClipboardItem(content: .image(data, metadata: meta),
                                 copiedDate: Date(), sourceApp: sourceApp)
        }

        // Color
        if let color = pb.readObjects(forClasses: [NSColor.self], options: nil)?.first as? NSColor {
            let hex = color.hexString ?? "#000000"
            return ClipboardItem(content: .color(hex: hex), copiedDate: Date(), sourceApp: sourceApp)
        }

        // String-based types
        guard let string = pb.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // URL
        if let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme, ["http", "https", "ftp", "file"].contains(scheme) {
            return ClipboardItem(content: .url(url), copiedDate: Date(), sourceApp: sourceApp)
        }

        // Code detection
        if looksLikeCode(string) {
            let lang = detectLanguage(string)
            return ClipboardItem(content: .code(string, language: lang),
                                 copiedDate: Date(), sourceApp: sourceApp)
        }

        // Plain text
        return ClipboardItem(content: .text(string), copiedDate: Date(), sourceApp: sourceApp)
    }

    private func looksLikeCode(_ text: String) -> Bool {
        let indicators = ["func ", "class ", "struct ", "let ", "var ", "import ",
                         "def ", "const ", "function ", "return ", "if (", "for (", "=>", "->",
                         "#!/", "#include", "package ", "public class"]
        let matches = indicators.filter { text.contains($0) }.count
        return matches >= 2 && text.contains("\n")
    }

    private func detectLanguage(_ text: String) -> String? {
        if text.contains("func ") && (text.contains("var ") || text.contains("let ")) { return "swift" }
        if text.contains("def ") || text.contains("import os") || text.contains("print(") { return "python" }
        if text.contains("function ") || text.contains("const ") || text.contains("=>") { return "javascript" }
        if text.contains("fun ") && text.contains("val ") { return "kotlin" }
        if text.contains("public class") || text.contains("System.out") { return "java" }
        if text.contains("#include") || text.contains("std::") { return "cpp" }
        return nil
    }

    private func imageMetadata(from data: Data) -> String? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        let kb = data.count / 1024
        return String(format: "%.0f×%.0f px · %d KB", size.width, size.height, kb)
    }
}

// MARK: - NSColor Hex Extension

private extension NSColor {
    var hexString: String? {
        guard let color = self.usingColorSpace(.sRGB) else { return nil }
        let r = Int(color.redComponent * 255)
        let g = Int(color.greenComponent * 255)
        let b = Int(color.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
