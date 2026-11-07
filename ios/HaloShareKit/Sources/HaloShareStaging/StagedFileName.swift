import Foundation

/// Turns whatever name another app gave a shared item into one that is a single, harmless path
/// component. Staged names later become the file name the *receiver* sees, so this is also the
/// first line of defence against a hostile name.
public enum StagedFileName {

    public static func sanitize(_ raw: String?, fallback: String = "file", maxLength: Int = 120) -> String {
        var name = (raw ?? "")
        // A path or a URL slipped in as a "name": keep the last component only.
        name = name.replacingOccurrences(of: "\\", with: "/")
        if let last = name.split(separator: "/", omittingEmptySubsequences: true).last { name = String(last) } else { name = "" }

        // Control characters, NUL, the characters Files/HFS+ mangle.
        let banned = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: ":*?\"<>|"))
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { !banned.contains($0) }))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // No hidden files and no "." / ".." — a leading dot is stripped, which also kills "..".
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = fallback }

        if name.count > maxLength {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, ext.count <= 12 {
                let stem = String((name as NSString).deletingPathExtension.prefix(max(1, maxLength - ext.count - 1)))
                name = stem + "." + ext
            } else {
                name = String(name.prefix(maxLength))
            }
        }
        return name
    }
}
