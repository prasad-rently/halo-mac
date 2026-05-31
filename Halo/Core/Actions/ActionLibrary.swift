import Foundation
import SwiftUI

// MARK: - ActionLibrary

/// Central registry of built-in and user-created custom actions.
/// Singleton — shared across ActionsView, QuickActionPickerController, and ActionRunner.
@MainActor
final class ActionLibrary: ObservableObject {

    static let shared = ActionLibrary()

    @Published private(set) var actions: [ActionItem] = []

    private let customKey = "haloCustomActions"
    private let usageKey  = "haloActionUsage"

    private init() { reload() }

    // MARK: - Load / Save

    func reload() {
        var all = ActionLibrary.predefined

        // Merge saved usage counts into predefined entries
        if let usageData = UserDefaults.standard.data(forKey: usageKey),
           let usageMap = try? JSONDecoder().decode([String: Int].self, from: usageData) {
            for i in all.indices {
                all[i].usageCount = usageMap[all[i].id.uuidString] ?? 0
            }
        }

        // Append persisted custom actions
        if let data   = UserDefaults.standard.data(forKey: customKey),
           let custom = try? JSONDecoder().decode([ActionItem].self, from: data) {
            all += custom
        }

        actions = all
    }

    private func persistCustomActions() {
        let custom = actions.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: customKey)
        }
    }

    private func persistUsage() {
        var map: [String: Int] = [:]
        for a in actions { map[a.id.uuidString] = a.usageCount }
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: usageKey)
        }
    }

    // MARK: - Mutations

    func recordUsage(of action: ActionItem) {
        if let idx = actions.firstIndex(where: { $0.id == action.id }) {
            actions[idx].usageCount += 1
            actions[idx].lastUsed = Date()
        }
        persistUsage()
    }

    func add(custom action: ActionItem) {
        var a = action; a.isBuiltIn = false
        actions.append(a)
        persistCustomActions()
    }

    func update(_ action: ActionItem) {
        if let idx = actions.firstIndex(where: { $0.id == action.id }) {
            actions[idx] = action
        }
        if !action.isBuiltIn { persistCustomActions() }
    }

    func delete(_ action: ActionItem) {
        actions.removeAll { $0.id == action.id }
        persistCustomActions()
    }

    func togglePin(_ action: ActionItem) {
        if let idx = actions.firstIndex(where: { $0.id == action.id }) {
            actions[idx].isPinned.toggle()
        }
        if !action.isBuiltIn { persistCustomActions() }
        else { persistUsage() }
    }

    // MARK: - Search / Suggestions

    /// Returns ENABLED actions ranked by fuzzy relevance to `query`.
    /// Custom actions are always shown regardless of the enabled-keys setting
    /// (the user explicitly created them). Built-in actions are filtered by
    /// ActionSettingsStore.shared.enabledKeys.
    func search(query: String) -> [ActionItem] {
        let pool    = enabledActions
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return pool.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.usageCount > $1.usageCount
            }
        }
        let terms = normalize(trimmed).split(separator: " ").map(String.init)
        return pool
            .compactMap { a -> (ActionItem, Int)? in
                let s = score(a, terms: terms)
                return s > 0 ? (a, s) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1  { return lhs.1 > rhs.1 }
                if lhs.0.isPinned != rhs.0.isPinned { return lhs.0.isPinned }
                return lhs.0.usageCount > rhs.0.usageCount
            }
            .map(\.0)
    }

    /// Actions visible in the Quick Actions picker (enabled built-ins + all custom).
    var enabledActions: [ActionItem] {
        let store = ActionSettingsStore.shared
        return actions.filter { a in
            !a.isBuiltIn || store.isEnabled(a.stableKey)
        }
    }

    // MARK: - Fuzzy scoring

    private func normalize(_ s: String) -> String {
        s.lowercased()
         .components(separatedBy: CharacterSet.alphanumerics.inverted)
         .filter { !$0.isEmpty }
         .joined(separator: " ")
    }

    private func score(_ action: ActionItem, terms: [String]) -> Int {
        let targets = ([action.name, action.subtitle] + action.keywords).map { normalize($0) }
        var total = 0
        for term in terms {
            var best = 0
            for t in targets {
                let words = t.split(separator: " ").map(String.init)
                // exact word match
                if words.contains(term)           { best = max(best, 100); continue }
                // prefix on any word
                if words.contains(where: { $0.hasPrefix(term) })  { best = max(best, 80); continue }
                // substring anywhere in target
                if t.contains(term)               { best = max(best, 60); continue }
                // fuzzy: every char of term appears in order in t
                if subsequenceMatch(term, in: t)  { best = max(best, 30) }
            }
            if best == 0 { return 0 }   // every term must match something
            total += best
        }
        return total
    }

    private func subsequenceMatch(_ needle: String, in haystack: String) -> Bool {
        var hi = haystack.startIndex
        for ch in needle {
            guard let found = haystack[hi...].firstIndex(of: ch) else { return false }
            hi = haystack.index(after: found)
        }
        return true
    }

    // MARK: - Predefined Actions

    // swiftlint:disable line_length
    static let predefined: [ActionItem] = [

        // ── Xcode ─────────────────────────────────────────────────────────
        ActionItem(
            name: "Clear Derived Data",
            subtitle: "Delete ~/Library/Developer/Xcode/DerivedData",
            icon: "trash.fill", iconColorHex: "#4f7cff", category: .xcode,
            keywords: ["derived data", "clean xcode", "delete derived", "xcode clean",
                       "clear build cache", "xcode derived", "remove derived"],
            command: .shell("""
                COUNT=$(du -sh ~/Library/Developer/Xcode/DerivedData 2>/dev/null | cut -f1 || echo "0")
                rm -rf ~/Library/Developer/Xcode/DerivedData
                echo "✓ Derived Data cleared (was ~$COUNT)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear SPM Cache",
            subtitle: "Remove Swift Package Manager resolved package cache",
            icon: "shippingbox.fill", iconColorHex: "#4f7cff", category: .xcode,
            keywords: ["spm", "swift package", "package cache", "swift pm",
                       "resolve packages", "spm cache", "clear packages"],
            command: .shell("""
                rm -rf ~/Library/Caches/org.swift.swiftpm
                rm -rf ~/Library/org.swift.swiftpm
                echo "✓ Swift Package Manager cache cleared."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Reset iOS Simulators",
            subtitle: "Erase all iOS/watchOS/tvOS simulator content and settings",
            icon: "iphone.slash", iconColorHex: "#4f7cff", category: .xcode,
            keywords: ["simulator", "ios simulator", "reset simulator",
                       "erase simulator", "clean simulator", "simctl erase"],
            command: .shell("""
                xcrun simctl erase all
                echo "✓ All simulators reset."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Kill Xcode",
            subtitle: "Force-quit Xcode (useful when it hangs)",
            icon: "xmark.app.fill", iconColorHex: "#ff4d6a", category: .xcode,
            keywords: ["kill xcode", "force quit xcode", "xcode hang", "xcode crash",
                       "quit xcode", "restart xcode"],
            // pkill returns non-zero if no process matched — suppress that exit code
            command: .shell("pkill -x Xcode && echo '✓ Xcode killed.' || echo 'ℹ Xcode is not running.'"),
            requiresPrivilege: false, isBuiltIn: true),

        // ── System ────────────────────────────────────────────────────────
        ActionItem(
            name: "Flush DNS Cache",
            subtitle: "Clear the macOS DNS resolver cache (requires admin)",
            icon: "globe.badge.chevron.backward", iconColorHex: "#22d97a", category: .system,
            keywords: ["dns", "flush dns", "clear dns", "dns cache",
                       "dns reset", "network dns", "domain name"],
            // Privileged: collapses to one semi-colon-separated line via runPrivileged
            command: .shell(
                "dscacheutil -flushcache\n" +
                "killall -HUP mDNSResponder\n" +
                "echo '✓ DNS cache flushed.'"
            ),
            requiresPrivilege: true, isBuiltIn: true),

        ActionItem(
            name: "Purge Inactive RAM",
            subtitle: "Force macOS to reclaim inactive memory pages (requires admin)",
            icon: "memorychip.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["ram", "memory", "purge", "free memory",
                       "clear ram", "inactive memory", "release ram"],
            command: .shell("purge\necho '✓ Inactive memory purged.'"),
            requiresPrivilege: true, isBuiltIn: true),

        ActionItem(
            name: "Empty Trash",
            subtitle: "Permanently delete everything in ~/.Trash",
            icon: "trash.slash.fill", iconColorHex: "#ff4d6a", category: .system,
            keywords: ["trash", "empty trash", "delete trash", "garbage", "bin", "rubbish"],
            // Uses a BuiltInAction that runs NSAppleScript (→ Finder) inside the Halo
            // process. Shell subprocesses cannot access ~/.Trash due to macOS ACLs;
            // running in-process via NSAppleScript bypasses that restriction.
            command: .builtIn(.emptyTrash),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Rebuild Spotlight Index",
            subtitle: "Force Spotlight to re-index the entire disk (requires admin)",
            icon: "magnifyingglass.circle.fill", iconColorHex: "#f5a623", category: .system,
            keywords: ["spotlight", "reindex", "search index", "mdutil",
                       "spotlight index", "rebuild index"],
            command: .shell(
                "mdutil -E /\n" +
                "echo '✓ Spotlight re-indexing started (runs in background).'"
            ),
            requiresPrivilege: true, isBuiltIn: true),

        ActionItem(
            name: "Repair Disk Permissions",
            subtitle: "Reset home directory permissions to macOS defaults",
            icon: "lock.rotation", iconColorHex: "#f5a623", category: .system,
            keywords: ["permissions", "disk permissions", "repair permissions",
                       "fix permissions", "file permissions"],
            command: .shell("""
                diskutil resetUserPermissions / $(id -u)
                echo "✓ User folder permissions repaired."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Toggle Microphone",
            subtitle: "Mute or unmute the system microphone globally across all apps",
            icon: "mic.fill", iconColorHex: "#ff4d6a", category: .system,
            keywords: ["mute", "unmute", "microphone", "mic", "silence mic",
                       "mute all", "meeting mute", "global mute", "mic off", "mic on"],
            command: .builtIn(.toggleMic),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Camera Privacy Settings",
            subtitle: "Open System Settings to manage per-app camera permissions",
            icon: "video.slash.fill", iconColorHex: "#f5a623", category: .system,
            keywords: ["camera", "camera off", "disable camera", "camera privacy",
                       "video off", "webcam", "camera permissions", "block camera"],
            command: .builtIn(.cameraPrivacy),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Network ───────────────────────────────────────────────────────
        ActionItem(
            name: "Run Speed Test",
            subtitle: "Measure current internet download and upload speeds",
            icon: "speedometer", iconColorHex: "#00d4e8", category: .network,
            keywords: ["speed", "speedtest", "internet speed", "bandwidth",
                       "download speed", "upload speed", "network speed", "speed test"],
            command: .builtIn(.runSpeedTest),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Check Connectivity",
            subtitle: "Ping Cloudflare (1.1.1.1) and Google DNS (8.8.8.8)",
            icon: "wifi.circle.fill", iconColorHex: "#00d4e8", category: .network,
            keywords: ["ping", "connectivity", "check internet", "network check",
                       "online", "connection test", "internet check"],
            // Avoid empty echo lines — they cause issues when collapsed to semicolons
            command: .shell("""
                echo "=== Cloudflare 1.1.1.1 ==="
                ping -c 4 -i 0.5 1.1.1.1
                echo "=== Google DNS 8.8.8.8 ==="
                ping -c 4 -i 0.5 8.8.8.8
                echo "✓ Connectivity check complete."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Show Network Interfaces",
            subtitle: "List all active network interfaces and IP addresses",
            icon: "antenna.radiowaves.left.and.right", iconColorHex: "#00d4e8", category: .network,
            keywords: ["network interfaces", "ip address", "ifconfig", "network info",
                       "mac address", "network adapter", "show ip"],
            command: .shell("ifconfig | grep -E '^[a-z0-9]|inet ' | sed 's/^[[:space:]]*//'"),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Halo ──────────────────────────────────────────────────────────
        ActionItem(
            name: "Run Smart Scan",
            subtitle: "Scan for junk files, threats, and performance issues",
            icon: "sparkles", iconColorHex: "#7b5ea7", category: .halo,
            keywords: ["scan", "smart scan", "halo scan", "clean scan",
                       "full scan", "scan mac", "analyze mac"],
            command: .builtIn(.runSmartScan),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Export Health Report",
            subtitle: "Generate and save a 4-page PDF system health report",
            icon: "doc.text.fill", iconColorHex: "#7b5ea7", category: .halo,
            keywords: ["report", "pdf", "export", "health report", "system report", "generate report"],
            command: .builtIn(.exportReport),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Clipboard History",
            subtitle: "Delete all entries from the Halo clipboard history",
            icon: "doc.on.clipboard", iconColorHex: "#f5a623", category: .halo,
            keywords: ["clipboard", "clear clipboard", "delete clipboard",
                       "clipboard history", "clipboard items"],
            command: .builtIn(.clearClipboard),
            requiresPrivilege: false, isBuiltIn: true),
    ]
    // swiftlint:enable line_length
}
