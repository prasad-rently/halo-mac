import AppKit

// MARK: - SyntaxHighlighter

/// Regex-based syntax highlighter that produces an NSAttributedString
/// with colors from a CodeTheme. Not a full parser — covers the most
/// common token types for visual appeal in code screenshots.
final class SyntaxHighlighter {

    /// Highlight `code` for the given language and theme.
    func highlight(code: String, language: CodeLanguage, theme: CodeTheme,
                   fontSize: CGFloat = 13) -> NSAttributedString {

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let result = NSMutableAttributedString(
            string: code,
            attributes: [
                .foregroundColor: theme.foreground,
                .font: font
            ]
        )

        let fullRange = NSRange(location: 0, length: (code as NSString).length)

        // 1. Comments (// and /* */ and # for Python/Bash)
        applyPattern(#"//[^\n]*"#, color: theme.comment, to: result, in: fullRange)
        applyPattern(#"/\*[\s\S]*?\*/"#, color: theme.comment, to: result, in: fullRange)
        if language == .python || language == .bash || language == .ruby {
            applyPattern(#"#[^\n]*"#, color: theme.comment, to: result, in: fullRange)
        }
        // HTML comments
        if language == .html {
            applyPattern(#"<!--[\s\S]*?-->"#, color: theme.comment, to: result, in: fullRange)
        }

        // 2. Strings (double-quoted, single-quoted, backtick template literals)
        applyPattern(#""(?:[^"\\]|\\.)*""#, color: theme.string, to: result, in: fullRange)
        applyPattern(#"'(?:[^'\\]|\\.)*'"#, color: theme.string, to: result, in: fullRange)
        applyPattern(#"`(?:[^`\\]|\\.)*`"#, color: theme.string, to: result, in: fullRange)
        // Python triple-quoted strings
        if language == .python {
            applyPattern(#"\"\"\"[\s\S]*?\"\"\""#, color: theme.string, to: result, in: fullRange)
            applyPattern(#"'''[\s\S]*?'''"#, color: theme.string, to: result, in: fullRange)
        }

        // 3. Numbers
        applyPattern(#"\b\d+\.?\d*([eE][+-]?\d+)?\b"#, color: theme.number, to: result, in: fullRange)
        applyPattern(#"\b0[xX][0-9a-fA-F]+\b"#, color: theme.number, to: result, in: fullRange)

        // 4. Keywords (language-specific)
        let kws = language.keywords
        if !kws.isEmpty {
            let escaped = kws.map { NSRegularExpression.escapedPattern(for: $0) }
            let pattern = "\\b(" + escaped.joined(separator: "|") + ")\\b"
            applyPattern(pattern, color: theme.keyword, to: result, in: fullRange)
        }

        // 5. Function calls — word followed by (
        applyPattern(#"\b([a-zA-Z_]\w*)\s*(?=\()"#, color: theme.function, to: result, in: fullRange)

        // 6. Type names — capitalized words (rough heuristic)
        if language != .json && language != .html && language != .css && language != .plaintext {
            applyPattern(#"\b[A-Z][a-zA-Z0-9]*\b"#, color: theme.type, to: result, in: fullRange)
        }

        // 7. Operators
        applyPattern(#"[+\-*/%=<>!&|^~?:]+"#, color: theme.operator_, to: result, in: fullRange)

        // 8. HTML/CSS specific — tags and properties
        if language == .html {
            applyPattern(#"</?[a-zA-Z][a-zA-Z0-9]*"#, color: theme.keyword, to: result, in: fullRange)
            applyPattern(#"\b[a-zA-Z\-]+(?==)"#, color: theme.function, to: result, in: fullRange)
        }
        if language == .css {
            applyPattern(#"[.#][a-zA-Z][a-zA-Z0-9_\-]*"#, color: theme.function, to: result, in: fullRange)
            applyPattern(#"[a-zA-Z\-]+(?=\s*:)"#, color: theme.keyword, to: result, in: fullRange)
        }

        // 9. JSON keys
        if language == .json {
            applyPattern(#""[^"]*"\s*(?=:)"#, color: theme.keyword, to: result, in: fullRange)
        }

        return result
    }

    // MARK: - Private

    private func applyPattern(_ pattern: String, color: NSColor,
                              to attrStr: NSMutableAttributedString, in range: NSRange) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        let matches = regex.matches(in: attrStr.string, options: [], range: range)
        for match in matches {
            attrStr.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
