import SwiftUI
import AppKit

// MARK: - CodeBeautifierView

struct CodeBeautifierView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var selectedTheme: CodeTheme = .midnight
    @State private var selectedLanguage: CodeLanguage = .plaintext
    @State private var padding: CGFloat = 64
    @State private var showBackground = true
    @State private var showLineNumbers = true
    @State private var showWindowChrome = true
    @State private var fileName = ""
    @State private var exportScale: CGFloat = 4   // 2x or 4x

    @State private var statusMessage: String?
    @State private var hasLoadedClipboard = false

    private let highlighter = SyntaxHighlighter()
    private let paddings: [CGFloat] = [16, 32, 64, 128]

    var body: some View {
        HSplitView {
            // Left: Preview
            previewPane
                .frame(minWidth: 400)

            // Right: Controls
            controlsPane
                .frame(width: 260)
        }
        .frame(minWidth: 750, minHeight: 520)
        .background(Color.haloBackground)
        .onAppear { loadFromClipboard() }
    }

    // MARK: - Preview Pane

    @ViewBuilder private var previewPane: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Preview")
                    .font(HaloFont.body(13, weight: .semibold))
                    .foregroundColor(.haloText)
                Spacer()
                if let msg = statusMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.haloGreen)
                            .font(.system(size: 11))
                        Text(msg)
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // Live code card preview
            ScrollView([.horizontal, .vertical]) {
                codeCard
                    .padding(24)
            }
            .background(Color(hex: "#1a1a2e").opacity(0.5))
        }
    }

    // MARK: - Code Card (the rendered output)

    @ViewBuilder private var codeCard: some View {
        VStack(spacing: 0) {
            if showWindowChrome {
                // Window chrome: traffic lights + file name
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#ff5f57")).frame(width: 12, height: 12)
                        Circle().fill(Color(hex: "#febc2e")).frame(width: 12, height: 12)
                        Circle().fill(Color(hex: "#28c840")).frame(width: 12, height: 12)
                    }
                    Spacer()
                    if !fileName.isEmpty {
                        Text(fileName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    // Balance spacing
                    Color.clear.frame(width: 54, height: 12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }

            // Code content
            HStack(alignment: .top, spacing: 0) {
                if showLineNumbers {
                    // Line numbers
                    VStack(alignment: .trailing, spacing: 0) {
                        let lines = code.components(separatedBy: "\n")
                        ForEach(0..<max(lines.count, 1), id: \.self) { i in
                            Text("\(i + 1)")
                                .font(.system(size: 13, weight: .regular, design: .monospaced))
                                .foregroundColor(Color(nsColor: selectedTheme.lineNumber))
                                .frame(height: 20)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
                }

                // Highlighted code
                HighlightedTextView(
                    attributedString: highlighter.highlight(
                        code: code, language: selectedLanguage, theme: selectedTheme
                    )
                )
                .padding(.trailing, 16)
                .padding(.leading, showLineNumbers ? 0 : 16)
            }
            .padding(.vertical, showWindowChrome ? 8 : 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor(hex: "#1e1e2e")).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(showBackground ? padding : 0)
        .background(
            Group {
                if showBackground {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: selectedTheme.gradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
        )
        .cornerRadius(showBackground ? 16 : 12)
    }

    // MARK: - Controls Pane

    @ViewBuilder private var controlsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(HaloFont.display(16, weight: .bold))
                    .foregroundColor(.haloText)

                // Theme
                VStack(alignment: .leading, spacing: 6) {
                    Text("Theme")
                        .font(HaloFont.body(11, weight: .semibold))
                        .foregroundColor(.haloText3)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 6) {
                        ForEach(CodeTheme.all) { theme in
                            Button {
                                selectedTheme = theme
                            } label: {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(LinearGradient(colors: theme.gradientColors,
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(height: 28)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(selectedTheme.id == theme.id
                                                        ? Color.haloAccent : Color.clear, lineWidth: 2)
                                        )
                                    Text(theme.name)
                                        .font(HaloFont.body(9))
                                        .foregroundColor(.haloText3)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().background(Color.haloBorder)

                // Language
                VStack(alignment: .leading, spacing: 6) {
                    Text("Language")
                        .font(HaloFont.body(11, weight: .semibold))
                        .foregroundColor(.haloText3)
                    Picker("", selection: $selectedLanguage) {
                        ForEach(CodeLanguage.allCases) { lang in
                            Text(lang.rawValue).tag(lang)
                        }
                    }
                    .labelsHidden()
                }

                Divider().background(Color.haloBorder)

                // Padding
                VStack(alignment: .leading, spacing: 6) {
                    Text("Padding")
                        .font(HaloFont.body(11, weight: .semibold))
                        .foregroundColor(.haloText3)
                    Picker("", selection: $padding) {
                        ForEach(paddings, id: \.self) { p in
                            Text("\(Int(p))px").tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Toggles
                VStack(spacing: 8) {
                    Toggle("Background", isOn: $showBackground)
                    Toggle("Line Numbers", isOn: $showLineNumbers)
                    Toggle("Window Chrome", isOn: $showWindowChrome)
                }
                .font(HaloFont.body(12))
                .foregroundColor(.haloText2)
                .toggleStyle(.switch)
                .controlSize(.small)

                // File name
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Name")
                        .font(HaloFont.body(11, weight: .semibold))
                        .foregroundColor(.haloText3)
                    TextField("optional title", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                        .font(HaloFont.body(12))
                }

                Divider().background(Color.haloBorder)

                // Export scale
                VStack(alignment: .leading, spacing: 6) {
                    Text("Export Scale")
                        .font(HaloFont.body(11, weight: .semibold))
                        .foregroundColor(.haloText3)
                    Picker("", selection: $exportScale) {
                        Text("2x").tag(CGFloat(2))
                        Text("4x").tag(CGFloat(4))
                    }
                    .pickerStyle(.segmented)
                }

                // Export buttons
                VStack(spacing: 8) {
                    Button {
                        copyImageToClipboard()
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.clipboard")
                            Text("Copy Image")
                        }
                        .font(HaloFont.body(12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(LinearGradient(colors: [.haloAccent, .haloAccent2],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                        .cornerRadius(11)
                    }
                    .buttonStyle(.plain)

                    Button {
                        savePNG()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.doc")
                            Text("Save PNG (\(Int(exportScale))x)")
                        }
                        .font(HaloFont.body(12, weight: .medium))
                        .foregroundColor(.haloAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.haloAccent.opacity(0.1))
                        .cornerRadius(9)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.haloAccent.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(16)
        }
        .background(Color.haloSurface)
    }

    // MARK: - Clipboard

    private func loadFromClipboard() {
        guard !hasLoadedClipboard else { return }
        hasLoadedClipboard = true

        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            code = text
            selectedLanguage = CodeLanguage.detect(from: text)
        } else {
            code = "// Paste or type your code here\nfunc hello() {\n    print(\"Hello, World!\")\n}"
            selectedLanguage = .swift
        }
    }

    // MARK: - Export

    private func renderToImage(scale: CGFloat) -> NSImage? {
        let view = NSHostingView(rootView: codeCard)
        let fittingSize = view.fittingSize
        let scaledSize = NSSize(width: fittingSize.width * scale, height: fittingSize.height * scale)
        view.frame = NSRect(origin: .zero, size: fittingSize)

        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        bitmapRep.size = scaledSize
        view.cacheDisplay(in: view.bounds, to: bitmapRep)

        let image = NSImage(size: scaledSize)
        image.addRepresentation(bitmapRep)
        return image
    }

    private func copyImageToClipboard() {
        guard let image = renderToImage(scale: exportScale) else {
            statusMessage = "Failed to render image"
            return
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(pngData, forType: .png)
        statusMessage = "Image copied to clipboard"
        clearStatusAfterDelay()
    }

    private func savePNG() {
        guard let image = renderToImage(scale: exportScale) else { return }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName.isEmpty
            ? "code-\(selectedTheme.name.lowercased())-\(Int(exportScale))x.png"
            : "\(fileName)-\(Int(exportScale))x.png"

        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? pngData.write(to: url)
                DispatchQueue.main.async {
                    statusMessage = "Saved to \(url.lastPathComponent)"
                    clearStatusAfterDelay()
                }
            }
        }
    }

    private func clearStatusAfterDelay() {
        let msg = statusMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if statusMessage == msg { statusMessage = nil }
        }
    }
}

// MARK: - Highlighted Text View (NSViewRepresentable)

struct HighlightedTextView: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        textView.textStorage?.setAttributedString(attributedString)
    }
}
