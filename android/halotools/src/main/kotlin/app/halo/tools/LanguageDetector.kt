package app.halo.tools

/** Port of the desktop's `CodeLanguage.detect(from:)` heuristics, same order and conditions (plus an XML prolog check first). */
object LanguageDetector {
    fun detect(code: String): CodeLanguage {
        val t = code.trim().lowercase(java.util.Locale.ROOT)
        if (t.startsWith("<?xml")) return CodeLanguage.XML
        if (t.contains("import swiftui") || t.contains("func ") && t.contains("-> ")) return CodeLanguage.SWIFT
        if (t.contains("import foundation") || t.contains("@objc")) return CodeLanguage.SWIFT
        if (t.startsWith("def ") || t.contains("import ") && t.contains("print(")) return CodeLanguage.PYTHON
        if (t.contains("const ") && (t.contains("=>") || t.contains("require("))) return CodeLanguage.JAVASCRIPT
        if (t.contains(": string") || t.contains(": number") || t.contains("interface ")) return CodeLanguage.TYPESCRIPT
        if (t.contains("func ") && t.contains("package ")) return CodeLanguage.GO
        if (t.contains("fn ") && (t.contains("let mut") || t.contains("pub "))) return CodeLanguage.RUST
        if (t.contains("public class") || t.contains("public static void")) return CodeLanguage.JAVA
        if (t.startsWith("class ") && t.contains("end")) return CodeLanguage.RUBY
        if (t.contains("<!doctype") || t.contains("<html") || t.contains("<div")) return CodeLanguage.HTML
        if (t.contains("{") && (t.contains("color:") || t.contains("display:") || t.contains("margin:"))) return CodeLanguage.CSS
        if ((t.startsWith("{") || t.startsWith("[")) && t.contains(":")) return CodeLanguage.JSON
        if (t.startsWith("#!/") || t.startsWith("echo ") || t.contains("fi\n")) return CodeLanguage.BASH
        if (t.contains("select ") && t.contains("from ")) return CodeLanguage.SQL
        return CodeLanguage.PLAIN_TEXT
    }
}
