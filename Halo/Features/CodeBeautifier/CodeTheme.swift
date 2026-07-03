import SwiftUI
import AppKit

// MARK: - CodeTheme

struct CodeTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let backgroundFrom: Color
    let backgroundTo: Color
    let foreground: NSColor
    let keyword: NSColor
    let string: NSColor
    let comment: NSColor
    let function: NSColor
    let number: NSColor
    let type: NSColor
    let operator_: NSColor
    let lineNumber: NSColor

    var gradientColors: [Color] { [backgroundFrom, backgroundTo] }

    // MARK: - All themes

    static let all: [CodeTheme] = [midnight, noir, aurora, sunset, ocean, forest, candy, ice]

    static let midnight = CodeTheme(
        id: "midnight", name: "Midnight",
        backgroundFrom: Color(hex: "#0d1220"), backgroundTo: Color(hex: "#131928"),
        foreground: NSColor(hex: "#e2e8f0"), keyword: NSColor(hex: "#4f7cff"),
        string: NSColor(hex: "#22d97a"), comment: NSColor(hex: "#4a5568"),
        function: NSColor(hex: "#f5a623"), number: NSColor(hex: "#f59e0b"),
        type: NSColor(hex: "#00d4e8"), operator_: NSColor(hex: "#b06cff"),
        lineNumber: NSColor(hex: "#374151"))

    static let noir = CodeTheme(
        id: "noir", name: "Noir",
        backgroundFrom: Color(hex: "#000000"), backgroundTo: Color(hex: "#0a0a0a"),
        foreground: NSColor(hex: "#d4d4d4"), keyword: NSColor(hex: "#c792ea"),
        string: NSColor(hex: "#c3e88d"), comment: NSColor(hex: "#545454"),
        function: NSColor(hex: "#82aaff"), number: NSColor(hex: "#f78c6c"),
        type: NSColor(hex: "#ffcb6b"), operator_: NSColor(hex: "#89ddff"),
        lineNumber: NSColor(hex: "#333333"))

    static let aurora = CodeTheme(
        id: "aurora", name: "Aurora",
        backgroundFrom: Color(hex: "#0b1a0b"), backgroundTo: Color(hex: "#0d2818"),
        foreground: NSColor(hex: "#d4edda"), keyword: NSColor(hex: "#22d97a"),
        string: NSColor(hex: "#00d4e8"), comment: NSColor(hex: "#3a5a3a"),
        function: NSColor(hex: "#82ffa8"), number: NSColor(hex: "#b5ffb5"),
        type: NSColor(hex: "#66ffcc"), operator_: NSColor(hex: "#99ffbb"),
        lineNumber: NSColor(hex: "#2a4a2a"))

    static let sunset = CodeTheme(
        id: "sunset", name: "Sunset",
        backgroundFrom: Color(hex: "#1a0a05"), backgroundTo: Color(hex: "#2a1008"),
        foreground: NSColor(hex: "#fde2c8"), keyword: NSColor(hex: "#ff6b6b"),
        string: NSColor(hex: "#f5a623"), comment: NSColor(hex: "#5a3a2a"),
        function: NSColor(hex: "#ffd93d"), number: NSColor(hex: "#ff9f43"),
        type: NSColor(hex: "#ff6348"), operator_: NSColor(hex: "#ffbe76"),
        lineNumber: NSColor(hex: "#4a2a1a"))

    static let ocean = CodeTheme(
        id: "ocean", name: "Ocean",
        backgroundFrom: Color(hex: "#0a0e1a"), backgroundTo: Color(hex: "#0d1830"),
        foreground: NSColor(hex: "#ccd6f6"), keyword: NSColor(hex: "#64ffda"),
        string: NSColor(hex: "#a8ff78"), comment: NSColor(hex: "#3a4a6a"),
        function: NSColor(hex: "#82aaff"), number: NSColor(hex: "#c792ea"),
        type: NSColor(hex: "#80cbc4"), operator_: NSColor(hex: "#89ddff"),
        lineNumber: NSColor(hex: "#2a3a5a"))

    static let forest = CodeTheme(
        id: "forest", name: "Forest",
        backgroundFrom: Color(hex: "#0d1810"), backgroundTo: Color(hex: "#142018"),
        foreground: NSColor(hex: "#d0e8d0"), keyword: NSColor(hex: "#88c070"),
        string: NSColor(hex: "#e8d06c"), comment: NSColor(hex: "#4a6040"),
        function: NSColor(hex: "#b0e080"), number: NSColor(hex: "#d0a060"),
        type: NSColor(hex: "#70c0a0"), operator_: NSColor(hex: "#a0d080"),
        lineNumber: NSColor(hex: "#3a5030"))

    static let candy = CodeTheme(
        id: "candy", name: "Candy",
        backgroundFrom: Color(hex: "#1a0820"), backgroundTo: Color(hex: "#200a28"),
        foreground: NSColor(hex: "#f0e0ff"), keyword: NSColor(hex: "#ff79c6"),
        string: NSColor(hex: "#f1fa8c"), comment: NSColor(hex: "#5a3a6a"),
        function: NSColor(hex: "#bd93f9"), number: NSColor(hex: "#ffb86c"),
        type: NSColor(hex: "#8be9fd"), operator_: NSColor(hex: "#ff79c6"),
        lineNumber: NSColor(hex: "#4a2a5a"))

    static let ice = CodeTheme(
        id: "ice", name: "Ice",
        backgroundFrom: Color(hex: "#0e1620"), backgroundTo: Color(hex: "#121e30"),
        foreground: NSColor(hex: "#e0eaf8"), keyword: NSColor(hex: "#7ec8e3"),
        string: NSColor(hex: "#a3d5ff"), comment: NSColor(hex: "#3a5070"),
        function: NSColor(hex: "#c5e1ff"), number: NSColor(hex: "#8eb8ff"),
        type: NSColor(hex: "#7ec8e3"), operator_: NSColor(hex: "#b0d0f0"),
        lineNumber: NSColor(hex: "#2a4060"))
}

// MARK: - NSColor hex helper

extension NSColor {
    convenience init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - CodeLanguage

enum CodeLanguage: String, CaseIterable, Identifiable {
    case swift       = "Swift"
    case python      = "Python"
    case javascript  = "JavaScript"
    case typescript   = "TypeScript"
    case go          = "Go"
    case rust        = "Rust"
    case java        = "Java"
    case ruby        = "Ruby"
    case html        = "HTML"
    case css         = "CSS"
    case json        = "JSON"
    case bash        = "Bash"
    case sql         = "SQL"
    case plaintext   = "Plain Text"

    var id: String { rawValue }

    /// Heuristic auto-detection from code content.
    static func detect(from code: String) -> CodeLanguage {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed.contains("import swiftui") || trimmed.contains("func ") && trimmed.contains("-> ") { return .swift }
        if trimmed.contains("import foundation") || trimmed.contains("@objc") { return .swift }
        if trimmed.hasPrefix("def ") || trimmed.contains("import ") && trimmed.contains("print(") { return .python }
        if trimmed.contains("const ") && (trimmed.contains("=>") || trimmed.contains("require(")) { return .javascript }
        if trimmed.contains(": string") || trimmed.contains(": number") || trimmed.contains("interface ") { return .typescript }
        if trimmed.contains("func ") && trimmed.contains("package ") { return .go }
        if trimmed.contains("fn ") && (trimmed.contains("let mut") || trimmed.contains("pub ")) { return .rust }
        if trimmed.contains("public class") || trimmed.contains("public static void") { return .java }
        if trimmed.hasPrefix("class ") && trimmed.contains("end") { return .ruby }
        if trimmed.contains("<!doctype") || trimmed.contains("<html") || trimmed.contains("<div") { return .html }
        if trimmed.contains("{") && (trimmed.contains("color:") || trimmed.contains("display:") || trimmed.contains("margin:")) { return .css }
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && trimmed.contains(":") { return .json }
        if trimmed.hasPrefix("#!/") || trimmed.hasPrefix("echo ") || trimmed.contains("fi\n") { return .bash }
        if trimmed.contains("select ") && trimmed.contains("from ") { return .sql }

        return .plaintext
    }

    /// Keywords for this language (used by SyntaxHighlighter).
    var keywords: [String] {
        switch self {
        case .swift:      return ["import", "func", "var", "let", "if", "else", "for", "in", "return", "struct", "class", "enum", "protocol", "guard", "switch", "case", "default", "break", "continue", "while", "repeat", "defer", "throw", "throws", "try", "catch", "async", "await", "actor", "some", "any", "where", "typealias", "extension", "init", "deinit", "self", "Self", "super", "nil", "true", "false", "static", "private", "public", "internal", "fileprivate", "open", "final", "override", "mutating", "nonmutating", "lazy", "weak", "unowned", "inout", "associatedtype"]
        case .python:     return ["def", "class", "import", "from", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "with", "as", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "True", "False", "None", "async", "await", "print", "self"]
        case .javascript: return ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "new", "this", "class", "extends", "import", "export", "default", "from", "try", "catch", "finally", "throw", "async", "await", "yield", "of", "in", "typeof", "instanceof", "delete", "void", "null", "undefined", "true", "false", "NaN"]
        case .typescript: return ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "new", "this", "class", "extends", "import", "export", "default", "from", "try", "catch", "finally", "throw", "async", "await", "interface", "type", "enum", "implements", "abstract", "readonly", "keyof", "typeof", "as", "is", "in", "of", "null", "undefined", "true", "false", "void", "never", "any", "unknown", "string", "number", "boolean"]
        case .go:         return ["package", "import", "func", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "select", "fallthrough", "nil", "true", "false", "iota", "make", "new", "len", "cap", "append", "copy", "delete", "error"]
        case .rust:       return ["fn", "let", "mut", "const", "if", "else", "for", "while", "loop", "match", "return", "break", "continue", "struct", "enum", "impl", "trait", "pub", "mod", "use", "crate", "self", "super", "as", "in", "ref", "move", "async", "await", "dyn", "where", "type", "unsafe", "extern", "true", "false", "Some", "None", "Ok", "Err"]
        case .java:       return ["public", "private", "protected", "class", "interface", "extends", "implements", "static", "final", "abstract", "void", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "new", "this", "super", "try", "catch", "finally", "throw", "throws", "import", "package", "instanceof", "null", "true", "false", "int", "long", "double", "float", "boolean", "char", "byte", "short", "String"]
        case .ruby:       return ["def", "end", "class", "module", "if", "elsif", "else", "unless", "case", "when", "while", "until", "for", "do", "begin", "rescue", "ensure", "raise", "return", "yield", "block_given?", "self", "super", "nil", "true", "false", "require", "include", "extend", "attr_reader", "attr_writer", "attr_accessor", "puts", "print"]
        case .html:       return ["html", "head", "body", "div", "span", "p", "a", "img", "input", "button", "form", "table", "tr", "td", "th", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "script", "style", "link", "meta", "title", "section", "header", "footer", "nav", "main", "article"]
        case .css:        return ["color", "background", "margin", "padding", "border", "display", "position", "width", "height", "font", "text", "flex", "grid", "align", "justify", "overflow", "opacity", "transform", "transition", "animation", "none", "auto", "inherit", "initial", "important"]
        case .json:       return []
        case .bash:       return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "exit", "echo", "read", "export", "source", "local", "set", "unset", "shift", "trap", "true", "false"]
        case .sql:        return ["SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "TABLE", "INTO", "VALUES", "SET", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "AS", "DISTINCT", "COUNT", "SUM", "AVG", "MAX", "MIN", "INDEX", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CASCADE"]
        case .plaintext:  return []
        }
    }
}
