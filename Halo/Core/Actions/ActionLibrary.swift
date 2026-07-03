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

    /// Returns ALL actions ranked by fuzzy relevance to `query`.
    ///
    /// The ⌘⇧A Quick Action picker intentionally searches ALL actions —
    /// it is a comprehensive keyboard-driven tool and should never have a
    /// blind spot. The enabled/disabled preference from ActionSettingsStore
    /// applies only to the tile grid in ActionsView, not here.
    ///
    /// Empty query → most-used / pinned first.
    func search(query: String) -> [ActionItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return actions.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.usageCount > $1.usageCount
            }
        }
        let terms = normalize(trimmed).split(separator: " ").map(String.init)
        return actions
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

    /// Subset used by ActionsView tile grid — respects ActionSettingsStore enabled/disabled.
    /// Custom actions are always included regardless of settings.
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

        // ── Developer ────────────────────────────────────────────────────

        ActionItem(
            name: "Remove node_modules",
            subtitle: "Delete node_modules from Desktop & Downloads (top 2 levels)",
            icon: "trash.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["node", "node_modules", "npm", "javascript", "js",
                       "remove node", "delete node_modules", "free space"],
            command: .shell("""
                echo "Searching for node_modules…"
                FOUND=$(find ~/Desktop ~/Downloads ~/Developer ~/Projects -maxdepth 3 -name "node_modules" -type d 2>/dev/null)
                if [ -z "$FOUND" ]; then echo "ℹ No node_modules found."; exit 0; fi
                SIZE=$(echo "$FOUND" | xargs du -sh 2>/dev/null)
                echo "$SIZE"
                echo "$FOUND" | xargs rm -rf
                echo "✓ node_modules removed."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear npm Cache",
            subtitle: "Run npm cache clean --force to remove corrupt packages",
            icon: "shippingbox.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["npm", "npm cache", "node cache", "clear npm",
                       "npm clean", "javascript cache"],
            command: .shell("""
                npm cache clean --force 2>&1
                echo "✓ npm cache cleared."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Yarn Cache",
            subtitle: "Run yarn cache clean to free disk space",
            icon: "shippingbox.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["yarn", "yarn cache", "clear yarn", "yarn clean"],
            command: .shell("""
                yarn cache clean 2>&1
                echo "✓ Yarn cache cleared."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Kill Process on Port",
            subtitle: "Free port 3000 (or port number from clipboard)",
            icon: "xmark.circle.fill", iconColorHex: "#ff4d6a", category: .developer,
            keywords: ["port", "kill port", "free port", "3000", "8080",
                       "port in use", "address already in use", "lsof"],
            command: .shell("""
                PORT=$(pbpaste | grep -oE '^[0-9]{2,5}$' || echo "3000")
                PIDS=$(lsof -ti:"$PORT" 2>/dev/null)
                if [ -z "$PIDS" ]; then echo "ℹ No process on port $PORT."; exit 0; fi
                echo "$PIDS" | xargs kill -9
                echo "✓ Killed process(es) on port $PORT."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Show All Listening Ports",
            subtitle: "List all TCP ports with active listeners",
            icon: "list.bullet.rectangle.portrait.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["ports", "listening", "tcp", "lsof", "netstat",
                       "open ports", "port list", "active ports"],
            command: .shell("lsof -iTCP -sTCP:LISTEN -n -P | awk 'NR==1 || !/^$/' | head -40"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Copy SSH Public Key",
            subtitle: "Copy ~/.ssh/id_ed25519.pub (or id_rsa.pub) to clipboard",
            icon: "key.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["ssh", "ssh key", "public key", "id_rsa", "id_ed25519",
                       "copy key", "ssh pub", "github key"],
            command: .shell("""
                if [ -f ~/.ssh/id_ed25519.pub ]; then
                    cat ~/.ssh/id_ed25519.pub | pbcopy
                    echo "✓ ed25519 public key copied to clipboard."
                elif [ -f ~/.ssh/id_rsa.pub ]; then
                    cat ~/.ssh/id_rsa.pub | pbcopy
                    echo "✓ RSA public key copied to clipboard."
                else
                    echo "⚠ No SSH public key found in ~/.ssh/"
                    echo "  Generate one with: ssh-keygen -t ed25519"
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        // ── System (Phase 1 additions) ───────────────────────────────────

        ActionItem(
            name: "Restart Finder",
            subtitle: "Kill and relaunch Finder to fix stuck windows or icons",
            icon: "arrow.clockwise.circle.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["finder", "restart finder", "killall finder", "finder frozen",
                       "finder stuck", "relaunch finder", "refresh finder"],
            command: .shell("killall Finder && echo '✓ Finder restarted.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Restart Dock",
            subtitle: "Kill and relaunch Dock to fix stuck icons or animations",
            icon: "arrow.clockwise.circle.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["dock", "restart dock", "killall dock", "dock frozen",
                       "dock stuck", "relaunch dock", "refresh dock"],
            command: .shell("killall Dock && echo '✓ Dock restarted.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Restart Menu Bar",
            subtitle: "Restart SystemUIServer to fix frozen menu bar icons",
            icon: "arrow.clockwise.circle.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["menu bar", "systemuiserver", "restart menu", "menu bar frozen",
                       "status bar", "menu extras", "control center"],
            command: .shell("killall SystemUIServer && echo '✓ Menu bar restarted.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Toggle Hidden Files",
            subtitle: "Show or hide dotfiles in Finder",
            icon: "eye.slash.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["hidden files", "dotfiles", "show hidden", "toggle hidden",
                       "invisible files", "AppleShowAllFiles", ".hidden"],
            command: .shell("""
                CUR=$(defaults read com.apple.finder AppleShowAllFiles 2>/dev/null)
                if [ "$CUR" = "true" ] || [ "$CUR" = "YES" ]; then
                    defaults write com.apple.finder AppleShowAllFiles -bool false
                    killall Finder
                    echo "✓ Hidden files are now HIDDEN."
                else
                    defaults write com.apple.finder AppleShowAllFiles -bool true
                    killall Finder
                    echo "✓ Hidden files are now VISIBLE."
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Remove .DS_Store Files",
            subtitle: "Recursively delete Finder metadata files from home directory",
            icon: "xmark.bin.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["ds_store", "dsstore", ".ds_store", "finder metadata",
                       "remove ds_store", "clean ds_store", "git ds_store"],
            command: .shell("""
                COUNT=$(find ~ -name ".DS_Store" -maxdepth 6 2>/dev/null | wc -l | tr -d ' ')
                find ~ -name ".DS_Store" -maxdepth 6 -delete 2>/dev/null
                echo "✓ Removed $COUNT .DS_Store files."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Show Disk Usage by Folder",
            subtitle: "Display size of each top-level folder in your home directory",
            icon: "chart.bar.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["disk usage", "du", "folder size", "disk space",
                       "storage breakdown", "what's taking space"],
            command: .shell("du -sh ~/*/ 2>/dev/null | sort -rh | head -20"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Lock Screen",
            subtitle: "Instantly lock the screen without logging out",
            icon: "lock.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["lock", "lock screen", "sleep", "lock mac",
                       "screen lock", "away", "secure"],
            command: .shell("pmset displaysleepnow"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Set Volume to 0% (Mute)",
            subtitle: "Mute system audio output instantly",
            icon: "speaker.slash.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["mute", "volume", "silence", "volume 0", "sound off",
                       "mute audio", "mute sound", "no sound"],
            command: .shell("""
                osascript -e 'set volume output muted true'
                echo "✓ System audio muted."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Set Volume to 50%",
            subtitle: "Set system audio to a standard working volume",
            icon: "speaker.wave.2.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["volume", "volume 50", "half volume", "medium volume",
                       "set volume", "unmute", "sound on"],
            command: .shell("""
                osascript -e 'set volume output volume 50'
                osascript -e 'set volume output muted false'
                echo "✓ Volume set to 50%."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Generate Secure Password",
            subtitle: "Create a 20-char random password and copy to clipboard",
            icon: "lock.shield.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["password", "generate password", "random password", "secure password",
                       "strong password", "passgen", "openssl rand"],
            command: .shell("""
                PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)
                echo -n "$PW" | pbcopy
                echo "✓ 20-character password copied to clipboard."
                echo "  (starts with: ${PW:0:4}…)"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Generate UUID",
            subtitle: "Create a UUID v4 and copy to clipboard",
            icon: "number.circle.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["uuid", "guid", "unique id", "uuidgen", "generate id",
                       "random id", "identifier"],
            command: .shell("""
                ID=$(uuidgen)
                echo -n "$ID" | pbcopy
                echo "✓ UUID copied to clipboard:"
                echo "  $ID"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Network (Phase 1 additions) ──────────────────────────────────

        ActionItem(
            name: "Show Public IP Address",
            subtitle: "Display your current public-facing IP address",
            icon: "globe", iconColorHex: "#00d4e8", category: .network,
            keywords: ["public ip", "my ip", "ip address", "external ip",
                       "what is my ip", "wan ip", "ipify"],
            command: .shell("""
                IP=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)
                if [ -z "$IP" ]; then
                    echo "⚠ Could not determine public IP (no internet?)."
                else
                    echo -n "$IP" | pbcopy
                    echo "✓ Public IP: $IP (copied to clipboard)"
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Show Wi-Fi Password",
            subtitle: "Retrieve the password for the currently connected Wi-Fi network",
            icon: "wifi.circle.fill", iconColorHex: "#00d4e8", category: .network,
            keywords: ["wifi password", "wi-fi password", "wifi key", "network password",
                       "show password", "wifi secret", "share wifi"],
            command: .shell("""
                SSID=$(networksetup -getairportnetwork en0 2>/dev/null | sed 's/Current Wi-Fi Network: //')
                if [ -z "$SSID" ] || echo "$SSID" | grep -q "not associated"; then
                    echo "⚠ Not connected to Wi-Fi."; exit 0
                fi
                echo "Network: $SSID"
                PW=$(security find-generic-password -ga "$SSID" -D "AirPort network password" 2>&1 | grep "password:" | sed 's/password: "//' | sed 's/"$//')
                if [ -z "$PW" ]; then
                    echo "⚠ Could not retrieve password (Keychain access may be required)."
                else
                    echo -n "$PW" | pbcopy
                    echo "✓ Password copied to clipboard."
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Files ────────────────────────────────────────────────────────

        ActionItem(
            name: "Show Largest Files",
            subtitle: "Find the 20 largest files (>100 MB) in your home directory",
            icon: "doc.badge.arrow.up.fill", iconColorHex: "#34d399", category: .files,
            keywords: ["large files", "biggest files", "disk hog", "space usage",
                       "find large", "100mb", "big files", "storage"],
            command: .shell("""
                echo "Scanning for files > 100 MB…"
                find ~ -maxdepth 5 -type f -size +100M -exec du -sh {} \\; 2>/dev/null | sort -rh | head -20
                echo "✓ Scan complete."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Eject All External Disks",
            subtitle: "Safely eject all removable drives and SD cards",
            icon: "eject.fill", iconColorHex: "#34d399", category: .files,
            keywords: ["eject", "unmount", "usb", "external drive", "sd card",
                       "removable", "safely remove", "disconnect drive"],
            command: .shell("""
                osascript -e 'tell application "Finder" to eject (every disk whose ejectable is true)' 2>/dev/null
                echo "✓ All ejectable disks have been ejected."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Clipboard Utilities ──────────────────────────────────────────

        ActionItem(
            name: "Format JSON in Clipboard",
            subtitle: "Pretty-print minified JSON and copy back to clipboard",
            icon: "curlybraces", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["json", "format json", "pretty print", "json format",
                       "beautify json", "indent json", "json pretty"],
            command: .shell("""
                RESULT=$(pbpaste | python3 -m json.tool 2>&1)
                if [ $? -eq 0 ]; then
                    echo "$RESULT" | pbcopy
                    echo "✓ Formatted JSON copied to clipboard."
                    echo "$RESULT" | head -20
                    LINES=$(echo "$RESULT" | wc -l | tr -d ' ')
                    if [ "$LINES" -gt 20 ]; then echo "  … ($LINES lines total)"; fi
                else
                    echo "⚠ Clipboard does not contain valid JSON:"
                    echo "$RESULT"
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Count Words in Clipboard",
            subtitle: "Count words, characters, and lines in clipboard text",
            icon: "textformat.123", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["word count", "character count", "line count", "wc",
                       "count text", "text length", "clipboard length"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                WORDS=$(echo "$TEXT" | wc -w | tr -d ' ')
                CHARS=$(echo -n "$TEXT" | wc -c | tr -d ' ')
                LINES=$(echo "$TEXT" | wc -l | tr -d ' ')
                echo "Words:      $WORDS"
                echo "Characters: $CHARS"
                echo "Lines:      $LINES"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Sort Clipboard Lines",
            subtitle: "Sort lines alphabetically and copy back to clipboard",
            icon: "arrow.up.arrow.down", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["sort", "sort lines", "alphabetical", "order lines",
                       "sort text", "sort clipboard", "arrange lines"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                SORTED=$(echo "$TEXT" | sort)
                echo "$SORTED" | pbcopy
                LINES=$(echo "$SORTED" | wc -l | tr -d ' ')
                echo "✓ $LINES lines sorted and copied to clipboard."
                echo "$SORTED" | head -10
                if [ "$LINES" -gt 10 ]; then echo "  … ($LINES lines total)"; fi
                """),
            requiresPrivilege: false, isBuiltIn: true),
        // ── Creative Suite Cache Cleanup ─────────────────────────────────

        ActionItem(
            name: "Clear Final Cut Pro Render Cache",
            subtitle: "Delete FCP render files to free gigabytes of disk space",
            icon: "film.fill", iconColorHex: "#ec4899", category: .creative,
            keywords: ["final cut", "fcp", "render cache", "final cut pro",
                       "video cache", "fcp cache", "fcpx"],
            command: .shell("""
                DIR="$HOME/Movies/Final Cut Pro"
                if [ ! -d "$DIR" ]; then echo "ℹ Final Cut Pro folder not found at $DIR"; exit 0; fi
                SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
                find "$DIR" -name "Render Files" -type d -exec rm -rf {} + 2>/dev/null
                find "$DIR" -name "Transcoded Media" -type d -exec rm -rf {} + 2>/dev/null
                echo "✓ FCP render cache cleared (folder was ~$SIZE)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Motion Templates Cache",
            subtitle: "Remove Motion template render cache to fix slowdowns",
            icon: "wand.and.stars", iconColorHex: "#ec4899", category: .creative,
            keywords: ["motion", "motion templates", "apple motion", "fcp templates",
                       "motion cache", "template cache"],
            command: .shell("""
                DIR="$HOME/Library/Application Support/Motion/Library"
                if [ ! -d "$DIR" ]; then echo "ℹ Motion Library folder not found."; exit 0; fi
                SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
                rm -rf "$DIR"
                echo "✓ Motion template cache cleared (was ~$SIZE)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear DaVinci Resolve Cache",
            subtitle: "Delete Resolve cache folders to free disk space",
            icon: "film.stack.fill", iconColorHex: "#ec4899", category: .creative,
            keywords: ["davinci", "resolve", "davinci resolve", "resolve cache",
                       "blackmagic", "color grading"],
            command: .shell("""
                DIR="$HOME/Library/Application Support/DaVinci Resolve"
                if [ ! -d "$DIR" ]; then echo "ℹ DaVinci Resolve support folder not found."; exit 0; fi
                SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
                find "$DIR" -maxdepth 2 -name "CacheClip" -type d -exec rm -rf {} + 2>/dev/null
                find "$DIR" -maxdepth 2 -name "GPUCache" -type d -exec rm -rf {} + 2>/dev/null
                echo "✓ DaVinci Resolve cache cleared (folder was ~$SIZE)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Adobe Premiere Cache",
            subtitle: "Remove Media Cache files that cause Premiere slowdowns",
            icon: "play.rectangle.fill", iconColorHex: "#ec4899", category: .creative,
            keywords: ["premiere", "adobe premiere", "premiere pro", "media cache",
                       "premiere cache", "adobe cache"],
            command: .shell("""
                CACHE1="$HOME/Library/Application Support/Adobe/Common/Media Cache"
                CACHE2="$HOME/Library/Application Support/Adobe/Common/Media Cache Files"
                TOTAL=0
                for D in "$CACHE1" "$CACHE2"; do
                    if [ -d "$D" ]; then
                        S=$(du -sm "$D" 2>/dev/null | cut -f1)
                        TOTAL=$((TOTAL + S))
                        rm -rf "$D"
                    fi
                done
                if [ "$TOTAL" -eq 0 ]; then echo "ℹ No Premiere cache found."; else echo "✓ Cleared ~${TOTAL}MB of Premiere media cache."; fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear After Effects Cache",
            subtitle: "Delete AE disk cache to free space between projects",
            icon: "sparkles.rectangle.stack.fill", iconColorHex: "#ec4899", category: .creative,
            keywords: ["after effects", "ae", "ae cache", "adobe ae",
                       "after effects cache", "motion graphics"],
            command: .shell("""
                DIR="$HOME/Library/Caches/Adobe/After Effects"
                if [ ! -d "$DIR" ]; then echo "ℹ After Effects cache folder not found."; exit 0; fi
                SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
                rm -rf "$DIR"
                echo "✓ After Effects cache cleared (was ~$SIZE)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Photoshop Scratch Disk",
            subtitle: "Remove Photoshop temp files locked after crashes",
            icon: "paintbrush.pointed.fill", iconColorHex: "#ec4899", category: .creative,
            keywords: ["photoshop", "scratch disk", "photoshop temp", "adobe photoshop",
                       "ps cache", "photoshop cache"],
            command: .shell("""
                DIR="$HOME/Library/Application Support/Adobe/Photoshop"
                if [ ! -d "$DIR" ]; then
                    DIR=$(find "$HOME/Library/Application Support/Adobe" -maxdepth 1 -name "Adobe Photoshop*" -type d 2>/dev/null | head -1)
                fi
                if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then echo "ℹ Photoshop support folder not found."; exit 0; fi
                SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
                find "$DIR" -name "*.tmp" -delete 2>/dev/null
                find "$DIR" -name "PST*" -delete 2>/dev/null
                echo "✓ Photoshop scratch/temp files cleared (folder: ~$SIZE)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Lightroom Preview Cache",
            subtitle: "Remove .lrdata preview files to shrink catalog size",
            icon: "camera.filters", iconColorHex: "#ec4899", category: .creative,
            keywords: ["lightroom", "lightroom previews", "lrdata", "lightroom cache",
                       "adobe lightroom", "lr previews", "catalog previews"],
            command: .shell("""
                FOUND=$(find ~/Pictures -name "*.lrdata" -type d 2>/dev/null)
                if [ -z "$FOUND" ]; then echo "ℹ No Lightroom preview files found in ~/Pictures."; exit 0; fi
                SIZE=$(echo "$FOUND" | xargs du -sh 2>/dev/null)
                echo "$SIZE"
                echo "$FOUND" | xargs rm -rf
                echo "✓ Lightroom preview caches removed."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Figma Local Cache",
            subtitle: "Fix Figma Desktop slowdowns by clearing local cache",
            icon: "rectangle.3.group.fill", iconColorHex: "#ec4899", category: .creative,
            keywords: ["figma", "figma cache", "figma desktop", "figma slow",
                       "design tool", "ui design"],
            command: .shell("""
                DIR="$HOME/Library/Application Support/Figma"
                if [ ! -d "$DIR" ]; then echo "ℹ Figma support folder not found."; exit 0; fi
                SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
                rm -rf "$DIR/Desktop" "$DIR/Cache" "$DIR/GPUCache" "$DIR/blob_storage" 2>/dev/null
                echo "✓ Figma cache cleared (folder was ~$SIZE)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Logic Pro Cache",
            subtitle: "Remove sampler/plug-in caches to fix Logic startup lag",
            icon: "music.note.list", iconColorHex: "#ec4899", category: .creative,
            keywords: ["logic", "logic pro", "logic cache", "music production",
                       "garageband", "audio cache", "sampler cache"],
            command: .shell("""
                DIR="$HOME/Music/Audio Music Apps/Plug-In Settings"
                if [ ! -d "$DIR" ]; then echo "ℹ Logic Pro plug-in settings folder not found."; exit 0; fi
                SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
                rm -rf "$DIR"
                echo "✓ Logic Pro plug-in cache cleared (was ~$SIZE)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Sketch App Cache",
            subtitle: "Fix Sketch slowdowns on large design systems",
            icon: "pencil.and.ruler.fill", iconColorHex: "#ec4899", category: .creative,
            keywords: ["sketch", "sketch app", "sketch cache", "bohemian",
                       "sketch design", "sketch slow"],
            command: .shell("""
                DIR="$HOME/Library/Application Support/com.bohemiancoding.sketch3"
                if [ ! -d "$DIR" ]; then echo "ℹ Sketch support folder not found."; exit 0; fi
                SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
                rm -rf "$DIR/Cache" "$DIR/GPUCache" 2>/dev/null
                echo "✓ Sketch cache cleared (folder was ~$SIZE)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Clipboard Utilities (Phase 2 additions) ─────────────────────

        ActionItem(
            name: "Generate QR Code from Clipboard",
            subtitle: "Create a QR code PNG on Desktop from clipboard text",
            icon: "qrcode", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["qr", "qr code", "qrcode", "generate qr", "barcode",
                       "share link", "scan code"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                OUT="$HOME/Desktop/qrcode_$(date +%Y%m%d_%H%M%S).png"
                if python3 -c "import qrcode" 2>/dev/null; then
                    python3 -c "
                import qrcode
                img = qrcode.make('$(echo "$TEXT" | sed "s/'/\\\\'/g")')
                img.save('$OUT')
                "
                    echo "✓ QR code saved to Desktop."
                    echo "  Content: ${TEXT:0:60}…"
                elif which qrencode > /dev/null 2>&1; then
                    echo "$TEXT" | qrencode -o "$OUT" -s 10
                    echo "✓ QR code saved to Desktop."
                else
                    echo "⚠ No QR generator found."
                    echo "  Install with: pip3 install qrcode[pil]"
                    echo "  Or: brew install qrencode"
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "URL Encode Clipboard",
            subtitle: "Convert clipboard text to URL-safe %XX encoding",
            icon: "link.badge.plus", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["url encode", "percent encode", "urlencode", "encode url",
                       "percent encoding", "query string"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$TEXT")
                echo -n "$ENCODED" | pbcopy
                echo "✓ URL-encoded text copied to clipboard."
                echo "  $ENCODED"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "URL Decode Clipboard",
            subtitle: "Convert %XX encoded text back to readable form",
            icon: "link.badge.plus", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["url decode", "percent decode", "urldecode", "decode url",
                       "unquote", "decode percent"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                DECODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.unquote(sys.stdin.read().strip()))" <<< "$TEXT")
                echo -n "$DECODED" | pbcopy
                echo "✓ URL-decoded text copied to clipboard."
                echo "  $DECODED"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Base64 Encode Clipboard",
            subtitle: "Encode clipboard content to Base64 and copy back",
            icon: "lock.rectangle.fill", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["base64", "encode", "base64 encode", "b64",
                       "base 64", "encode clipboard"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                ENCODED=$(echo -n "$TEXT" | base64)
                echo -n "$ENCODED" | pbcopy
                echo "✓ Base64-encoded text copied to clipboard."
                echo "  ${ENCODED:0:80}…"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Base64 Decode Clipboard",
            subtitle: "Decode Base64 text from clipboard back to plain text",
            icon: "lock.rectangle.fill", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["base64 decode", "decode", "b64 decode", "base 64 decode",
                       "decode clipboard", "jwt decode"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                DECODED=$(echo "$TEXT" | base64 --decode 2>&1)
                if [ $? -eq 0 ]; then
                    echo -n "$DECODED" | pbcopy
                    echo "✓ Base64-decoded text copied to clipboard."
                    echo "  ${DECODED:0:200}"
                else
                    echo "⚠ Clipboard does not contain valid Base64."
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Minify JSON in Clipboard",
            subtitle: "Compact formatted JSON into a single line",
            icon: "curlybraces", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["json minify", "minify", "compact json", "compress json",
                       "json compact", "json single line"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                RESULT=$(python3 -c "import json, sys; data=json.load(sys.stdin); print(json.dumps(data, separators=(',',':')))" <<< "$TEXT" 2>&1)
                if [ $? -eq 0 ]; then
                    echo -n "$RESULT" | pbcopy
                    echo "✓ Minified JSON copied to clipboard."
                    echo "  ${RESULT:0:120}…"
                else
                    echo "⚠ Clipboard does not contain valid JSON:"
                    echo "$RESULT"
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Convert Clipboard to UPPERCASE",
            subtitle: "Transform all text in clipboard to uppercase",
            icon: "textformat.size.larger", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["uppercase", "upper case", "caps", "all caps",
                       "to upper", "capitalize all"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                echo -n "$TEXT" | tr '[:lower:]' '[:upper:]' | pbcopy
                echo "✓ Clipboard text converted to UPPERCASE."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Convert Clipboard to lowercase",
            subtitle: "Transform all text in clipboard to lowercase",
            icon: "textformat.size.smaller", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["lowercase", "lower case", "to lower", "uncapitalize",
                       "small letters", "downcase"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                echo -n "$TEXT" | tr '[:upper:]' '[:lower:]' | pbcopy
                echo "✓ Clipboard text converted to lowercase."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Remove Duplicate Lines",
            subtitle: "Deduplicate lines in clipboard and copy back",
            icon: "line.3.horizontal.decrease", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["dedup", "deduplicate", "unique lines", "remove duplicates",
                       "distinct", "unique", "sort unique"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                BEFORE=$(echo "$TEXT" | wc -l | tr -d ' ')
                RESULT=$(echo "$TEXT" | awk '!seen[$0]++')
                AFTER=$(echo "$RESULT" | wc -l | tr -d ' ')
                echo "$RESULT" | pbcopy
                REMOVED=$((BEFORE - AFTER))
                echo "✓ Removed $REMOVED duplicate lines ($BEFORE → $AFTER)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Strip Formatting from Clipboard",
            subtitle: "Convert rich text to plain text in clipboard",
            icon: "textformat.alt", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["strip formatting", "plain text", "remove formatting",
                       "paste plain", "clear formatting", "unformat"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                echo -n "$TEXT" | pbcopy
                echo "✓ Clipboard converted to plain text."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Hash Clipboard (SHA-256)",
            subtitle: "Generate SHA-256 hash of clipboard content",
            icon: "number.square.fill", iconColorHex: "#b06cff", category: .clipboard,
            keywords: ["sha256", "hash", "sha", "checksum", "digest",
                       "sha-256", "hash clipboard"],
            command: .shell("""
                TEXT=$(pbpaste)
                if [ -z "$TEXT" ]; then echo "ℹ Clipboard is empty."; exit 0; fi
                HASH=$(echo -n "$TEXT" | shasum -a 256 | awk '{print $1}')
                echo -n "$HASH" | pbcopy
                echo "✓ SHA-256 hash copied to clipboard:"
                echo "  $HASH"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Media, Image & Video Utilities ───────────────────────────────

        ActionItem(
            name: "Convert HEIC to JPEG",
            subtitle: "Convert a .heic file (path from clipboard) to JPEG",
            icon: "photo.on.rectangle.angled", iconColorHex: "#f59e0b", category: .media,
            keywords: ["heic", "jpeg", "convert heic", "heic to jpg", "iphone photo",
                       "heif", "image convert", "sips"],
            command: .shell("""
                FPATH=$(pbpaste | tr -d '\\n' | sed "s|~|$HOME|")
                if [ -z "$FPATH" ] || [ ! -f "$FPATH" ]; then
                    echo "⚠ Clipboard does not contain a valid file path."
                    echo "  Copy a .heic file path first."; exit 0
                fi
                EXT=$(echo "$FPATH" | tr '[:upper:]' '[:lower:]')
                if [[ "$EXT" != *.heic ]] && [[ "$EXT" != *.heif ]]; then
                    echo "⚠ File is not a HEIC/HEIF: $FPATH"; exit 0
                fi
                OUT="${FPATH%.*}.jpg"
                sips -s format jpeg -s formatOptions 90 "$FPATH" --out "$OUT" 2>&1
                echo "✓ Converted to JPEG: $OUT"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Optimise Images in Downloads",
            subtitle: "Resize oversized images in ~/Downloads to max 2560px wide",
            icon: "photo.badge.arrow.down.fill", iconColorHex: "#f59e0b", category: .media,
            keywords: ["optimise", "optimize", "resize images", "compress images",
                       "shrink images", "downloads images", "sips resize"],
            command: .shell("""
                COUNT=0
                for F in ~/Downloads/*.{jpg,jpeg,png,JPG,JPEG,PNG}; do
                    [ -f "$F" ] || continue
                    W=$(sips -g pixelWidth "$F" 2>/dev/null | awk '/pixelWidth/{print $2}')
                    if [ -n "$W" ] && [ "$W" -gt 2560 ]; then
                        sips --resampleWidth 2560 "$F" --out "$F" > /dev/null 2>&1
                        COUNT=$((COUNT + 1))
                        echo "  Resized: $(basename "$F") (${W}px → 2560px)"
                    fi
                done
                if [ "$COUNT" -eq 0 ]; then echo "ℹ No oversized images found in Downloads."; else echo "✓ Optimised $COUNT image(s)."; fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Get Video File Info",
            subtitle: "Show codec, resolution, and duration of a video file",
            icon: "film.fill", iconColorHex: "#f59e0b", category: .media,
            keywords: ["video info", "ffprobe", "codec", "resolution", "video details",
                       "media info", "video metadata", "fps"],
            command: .shell("""
                FPATH=$(pbpaste | tr -d '\\n' | sed "s|~|$HOME|")
                if [ -z "$FPATH" ] || [ ! -f "$FPATH" ]; then
                    echo "⚠ Clipboard does not contain a valid file path."
                    echo "  Copy a video file path first."; exit 0
                fi
                if which ffprobe > /dev/null 2>&1; then
                    ffprobe -v quiet -print_format json -show_format -show_streams "$FPATH" 2>/dev/null | python3 -c "
                import json, sys
                d = json.load(sys.stdin)
                fmt = d.get('format', {})
                print(f'File: {fmt.get(\"filename\", \"?\").split(\"/\")[-1]}')
                dur = float(fmt.get('duration', 0))
                m, s = divmod(int(dur), 60)
                print(f'Duration: {m}m {s}s')
                print(f'Size: {int(fmt.get(\"size\", 0)) // 1048576} MB')
                for st in d.get('streams', []):
                    if st['codec_type'] == 'video':
                        print(f'Video: {st.get(\"codec_name\",\"?\")} {st.get(\"width\",\"?\")}x{st.get(\"height\",\"?\")} @ {st.get(\"r_frame_rate\",\"?\")} fps')
                    elif st['codec_type'] == 'audio':
                        print(f'Audio: {st.get(\"codec_name\",\"?\")} {st.get(\"sample_rate\",\"?\")}Hz {st.get(\"channels\",\"?\")}ch')
                "
                else
                    mdls -name kMDItemCodecs -name kMDItemDurationSeconds -name kMDItemPixelHeight -name kMDItemPixelWidth "$FPATH" 2>/dev/null
                    echo ""
                    echo "ℹ Install ffmpeg for detailed info: brew install ffmpeg"
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Extract Audio from Video",
            subtitle: "Extract audio track from a video file (path from clipboard)",
            icon: "waveform", iconColorHex: "#f59e0b", category: .media,
            keywords: ["extract audio", "video to audio", "rip audio", "ffmpeg audio",
                       "audio extract", "m4a", "mp3 extract"],
            command: .shell("""
                FPATH=$(pbpaste | tr -d '\\n' | sed "s|~|$HOME|")
                if [ -z "$FPATH" ] || [ ! -f "$FPATH" ]; then
                    echo "⚠ Clipboard does not contain a valid file path."
                    echo "  Copy a video file path first."; exit 0
                fi
                if ! which ffmpeg > /dev/null 2>&1; then
                    echo "⚠ ffmpeg not found."
                    echo "  Install with: brew install ffmpeg"; exit 0
                fi
                OUT="${FPATH%.*}.m4a"
                ffmpeg -i "$FPATH" -vn -acodec copy "$OUT" -y 2>&1 | tail -3
                echo "✓ Audio extracted: $OUT"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Create GIF from Video",
            subtitle: "Convert a short video to an optimised GIF via ffmpeg",
            icon: "photo.on.rectangle", iconColorHex: "#f59e0b", category: .media,
            keywords: ["gif", "video to gif", "create gif", "make gif",
                       "animated gif", "ffmpeg gif", "convert gif"],
            command: .shell("""
                FPATH=$(pbpaste | tr -d '\\n' | sed "s|~|$HOME|")
                if [ -z "$FPATH" ] || [ ! -f "$FPATH" ]; then
                    echo "⚠ Clipboard does not contain a valid file path."
                    echo "  Copy a video file path first."; exit 0
                fi
                if ! which ffmpeg > /dev/null 2>&1; then
                    echo "⚠ ffmpeg not found."
                    echo "  Install with: brew install ffmpeg"; exit 0
                fi
                OUT="${FPATH%.*}.gif"
                PALETTE="/tmp/halo_palette.png"
                echo "Generating palette…"
                ffmpeg -y -i "$FPATH" -vf "fps=15,scale=480:-1:flags=lanczos,palettegen" "$PALETTE" 2>/dev/null
                echo "Creating GIF…"
                ffmpeg -y -i "$FPATH" -i "$PALETTE" -filter_complex "fps=15,scale=480:-1:flags=lanczos[x];[x][1:v]paletteuse" "$OUT" 2>/dev/null
                rm -f "$PALETTE"
                SIZE=$(du -sh "$OUT" | cut -f1)
                echo "✓ GIF created ($SIZE): $OUT"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Take Screenshot to Desktop",
            subtitle: "Capture the full screen silently and save to Desktop",
            icon: "camera.viewfinder", iconColorHex: "#f59e0b", category: .media,
            keywords: ["screenshot", "screen capture", "screencapture", "capture screen",
                       "print screen", "screen grab"],
            command: .shell("""
                OUT="$HOME/Desktop/screenshot_$(date +%Y%m%d_%H%M%S).png"
                screencapture -x "$OUT"
                echo "✓ Screenshot saved: $OUT"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Start 10-Second Screen Recording",
            subtitle: "Record the screen for 10 seconds and save to Desktop",
            icon: "record.circle", iconColorHex: "#f59e0b", category: .media,
            keywords: ["screen recording", "record screen", "video capture",
                       "screencapture video", "screen record", "10 second"],
            command: .shell("""
                OUT="$HOME/Desktop/recording_$(date +%Y%m%d_%H%M%S).mov"
                echo "Recording for 10 seconds…"
                screencapture -V 10 -x "$OUT"
                echo "✓ Recording saved: $OUT"
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Resize Image to 1080p",
            subtitle: "Resize image (path from clipboard) so longest side is 1920px",
            icon: "arrow.up.left.and.arrow.down.right", iconColorHex: "#f59e0b", category: .media,
            keywords: ["resize", "1080p", "resize image", "scale image", "1920",
                       "social media", "sips resize", "downscale"],
            command: .shell("""
                FPATH=$(pbpaste | tr -d '\\n' | sed "s|~|$HOME|")
                if [ -z "$FPATH" ] || [ ! -f "$FPATH" ]; then
                    echo "⚠ Clipboard does not contain a valid file path."
                    echo "  Copy an image file path first."; exit 0
                fi
                W=$(sips -g pixelWidth "$FPATH" 2>/dev/null | awk '/pixelWidth/{print $2}')
                H=$(sips -g pixelHeight "$FPATH" 2>/dev/null | awk '/pixelHeight/{print $2}')
                if [ -z "$W" ] || [ -z "$H" ]; then echo "⚠ Could not read image dimensions."; exit 0; fi
                if [ "$W" -ge "$H" ]; then
                    sips --resampleWidth 1920 "$FPATH" --out "$FPATH" > /dev/null 2>&1
                else
                    sips --resampleHeight 1920 "$FPATH" --out "$FPATH" > /dev/null 2>&1
                fi
                echo "✓ Resized to 1080p (was ${W}x${H}): $(basename "$FPATH")"
                """),
            requiresPrivilege: false, isBuiltIn: true),
        // ── Code Beautifier (F-038) ──────────────────────────────────────

        ActionItem(
            name: "Beautify Code",
            subtitle: "Create a beautiful code screenshot from clipboard content",
            icon: "paintbrush.pointed.fill", iconColorHex: "#8b5cf6", category: .clipboard,
            keywords: ["beautify", "code image", "screenshot code", "code snippet",
                       "syntax highlight", "ray.so", "code card", "pretty code",
                       "share code", "code png"],
            command: .builtIn(.beautifyCode),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Dock & Desktop (F-031) ───────────────────────────────────────

        ActionItem(
            name: "Add Dock Spacer",
            subtitle: "Insert a blank spacer tile in the Dock for visual grouping",
            icon: "square.split.2x1", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["dock spacer", "spacer tile", "dock gap", "dock separator",
                       "dock divider", "blank space", "organize dock"],
            command: .shell("defaults write com.apple.dock persistent-apps -array-add '{\"tile-type\"=\"spacer-tile\";}' && killall Dock && echo '✓ Spacer added to Dock.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Add Small Dock Spacer",
            subtitle: "Insert a thin half-width spacer tile in the Dock",
            icon: "square.split.2x1", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["small spacer", "thin spacer", "narrow spacer", "dock small gap",
                       "half spacer", "mini spacer"],
            command: .shell("defaults write com.apple.dock persistent-apps -array-add '{\"tile-type\"=\"small-spacer-tile\";}' && killall Dock && echo '✓ Small spacer added to Dock.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Reset Dock to Default",
            subtitle: "Remove all Dock customizations and restore macOS defaults",
            icon: "arrow.counterclockwise.circle.fill", iconColorHex: "#ff4d6a", category: .dock,
            keywords: ["reset dock", "default dock", "restore dock", "factory dock",
                       "dock reset", "clear dock", "original dock"],
            command: .shell("defaults delete com.apple.dock && killall Dock && echo '✓ Dock reset to macOS defaults.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Toggle Auto-Hide Dock",
            subtitle: "Enable or disable automatic Dock hiding",
            icon: "rectangle.bottomhalf.inset.filled", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["auto hide", "autohide", "hide dock", "show dock",
                       "dock visibility", "toggle dock", "dock auto"],
            command: .shell("osascript -e 'tell application \"System Events\" to tell dock preferences to set autohide to not autohide of dock preferences' && echo '✓ Dock auto-hide toggled.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Remove Auto-Hide Delay",
            subtitle: "Make the Dock appear instantly when you hover the edge",
            icon: "bolt.fill", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["autohide delay", "instant dock", "no delay", "dock speed",
                       "fast dock", "remove delay", "dock animation speed"],
            command: .shell("defaults write com.apple.dock autohide-delay -float 0 && defaults write com.apple.dock autohide-time-modifier -float 0.3 && killall Dock && echo '✓ Dock auto-hide delay removed.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Restore Auto-Hide Delay",
            subtitle: "Reset Dock hover delay and animation to macOS defaults",
            icon: "clock.arrow.circlepath", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["restore delay", "default delay", "reset autohide",
                       "dock default speed", "normal dock"],
            command: .shell("defaults delete com.apple.dock autohide-delay 2>/dev/null; defaults delete com.apple.dock autohide-time-modifier 2>/dev/null; killall Dock && echo '✓ Dock auto-hide delay restored to default.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Minimize Effect: Suck",
            subtitle: "Change window minimize animation to the hidden Suck effect",
            icon: "rectangle.compress.vertical", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["suck effect", "minimize suck", "suck animation",
                       "dock animation", "window minimize"],
            command: .shell("defaults write com.apple.dock mineffect suck && killall Dock && echo '✓ Minimize effect set to Suck.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Minimize Effect: Scale",
            subtitle: "Change window minimize animation to simple Scale",
            icon: "arrow.down.right.and.arrow.up.left", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["scale effect", "minimize scale", "scale animation",
                       "simple minimize", "fast minimize"],
            command: .shell("defaults write com.apple.dock mineffect scale && killall Dock && echo '✓ Minimize effect set to Scale.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Minimize Effect: Genie",
            subtitle: "Restore the default Genie minimize animation",
            icon: "wand.and.stars", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["genie effect", "minimize genie", "genie animation",
                       "default minimize", "restore genie"],
            command: .shell("defaults write com.apple.dock mineffect genie && killall Dock && echo '✓ Minimize effect set to Genie.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Hide Recent Apps from Dock",
            subtitle: "Remove the recently used apps section from the Dock",
            icon: "clock.badge.xmark", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["hide recents", "remove recents", "dock recents off",
                       "no recent apps", "recent apps dock"],
            command: .shell("defaults write com.apple.dock show-recents -bool false && killall Dock && echo '✓ Recent apps hidden from Dock.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Show Recent Apps in Dock",
            subtitle: "Restore the recently used apps section in the Dock",
            icon: "clock.badge.checkmark", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["show recents", "restore recents", "dock recents on",
                       "enable recent apps"],
            command: .shell("defaults write com.apple.dock show-recents -bool true && killall Dock && echo '✓ Recent apps shown in Dock.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Dock Position: Left",
            subtitle: "Move the Dock to the left side of the screen",
            icon: "rectangle.lefthalf.inset.filled", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["dock left", "move dock", "dock position left",
                       "left side dock", "dock orientation"],
            command: .shell("defaults write com.apple.dock orientation left && killall Dock && echo '✓ Dock moved to left.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Dock Position: Right",
            subtitle: "Move the Dock to the right side of the screen",
            icon: "rectangle.righthalf.inset.filled", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["dock right", "move dock", "dock position right",
                       "right side dock"],
            command: .shell("defaults write com.apple.dock orientation right && killall Dock && echo '✓ Dock moved to right.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Dock Position: Bottom",
            subtitle: "Move the Dock back to the bottom of the screen",
            icon: "rectangle.bottomhalf.inset.filled", iconColorHex: "#06b6d4", category: .dock,
            keywords: ["dock bottom", "move dock", "dock position bottom",
                       "default position", "dock center"],
            command: .shell("defaults write com.apple.dock orientation bottom && killall Dock && echo '✓ Dock moved to bottom.'"),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Display (F-032) ─────────────────────────────────────────────

        ActionItem(
            name: "Toggle Dark Mode",
            subtitle: "Switch between Light and Dark appearance system-wide",
            icon: "moon.fill", iconColorHex: "#8b5cf6", category: .display,
            keywords: ["dark mode", "light mode", "appearance", "theme",
                       "toggle dark", "switch theme", "night mode"],
            command: .shell("osascript -e 'tell app \"System Events\" to tell appearance preferences to set dark mode to not dark mode' && echo '✓ Dark mode toggled.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Screenshot to Clipboard",
            subtitle: "Capture the full screen and copy directly to clipboard",
            icon: "camera.viewfinder", iconColorHex: "#8b5cf6", category: .display,
            keywords: ["screenshot clipboard", "screen capture clipboard", "copy screen",
                       "capture clipboard", "screencap copy"],
            command: .shell("screencapture -c && echo '✓ Screenshot copied to clipboard.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Screenshot Region to Clipboard",
            subtitle: "Select a screen region to capture and copy to clipboard",
            icon: "crop", iconColorHex: "#8b5cf6", category: .display,
            keywords: ["region screenshot", "select area", "crop screenshot",
                       "partial screenshot", "snip", "selection capture"],
            command: .shell("screencapture -ic && echo '✓ Region screenshot copied to clipboard.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Screenshot with 5s Timer",
            subtitle: "Capture full screen after a 5-second countdown",
            icon: "timer", iconColorHex: "#8b5cf6", category: .display,
            keywords: ["timed screenshot", "delayed screenshot", "5 second",
                       "countdown screenshot", "timer capture"],
            command: .shell("""
                echo "Screenshot in 5 seconds…"
                screencapture -T5 "$HOME/Desktop/screenshot_$(date +%Y%m%d_%H%M%S).png"
                echo "✓ Screenshot saved to Desktop."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Toggle Desktop Icons",
            subtitle: "Show or hide all icons on the Desktop",
            icon: "desktopcomputer", iconColorHex: "#8b5cf6", category: .display,
            keywords: ["desktop icons", "hide icons", "show icons", "clean desktop",
                       "desktop files", "CreateDesktop", "minimal desktop"],
            command: .shell("""
                CUR=$(defaults read com.apple.finder CreateDesktop 2>/dev/null)
                if [ "$CUR" = "0" ] || [ "$CUR" = "false" ]; then
                    defaults write com.apple.finder CreateDesktop -bool true
                    killall Finder
                    echo "✓ Desktop icons are now VISIBLE."
                else
                    defaults write com.apple.finder CreateDesktop -bool false
                    killall Finder
                    echo "✓ Desktop icons are now HIDDEN."
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Open Display Settings",
            subtitle: "Jump directly to System Settings → Displays",
            icon: "gear", iconColorHex: "#8b5cf6", category: .display,
            keywords: ["display settings", "resolution", "refresh rate", "monitor settings",
                       "screen settings", "display preferences"],
            command: .shell("open 'x-apple.systempreferences:com.apple.Displays-Settings.extension' && echo '✓ Opened Display Settings.'"),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Audio (F-032) ───────────────────────────────────────────────

        ActionItem(
            name: "Mute Microphone",
            subtitle: "Set microphone input volume to zero",
            icon: "mic.slash.fill", iconColorHex: "#14b8a6", category: .audio,
            keywords: ["mute mic", "microphone off", "disable mic", "mic mute",
                       "silence mic", "input mute", "meeting mute"],
            command: .shell("osascript -e 'set volume input volume 0' && echo '✓ Microphone muted.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Unmute Microphone",
            subtitle: "Restore microphone input volume to 100%",
            icon: "mic.fill", iconColorHex: "#14b8a6", category: .audio,
            keywords: ["unmute mic", "microphone on", "enable mic", "mic unmute",
                       "input unmute", "restore mic"],
            command: .shell("osascript -e 'set volume input volume 100' && echo '✓ Microphone unmuted (100%).'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Set Volume to 25%",
            subtitle: "Lower system audio to a quiet level",
            icon: "speaker.wave.1.fill", iconColorHex: "#14b8a6", category: .audio,
            keywords: ["volume 25", "quiet", "low volume", "volume down",
                       "reduce volume", "soft"],
            command: .shell("osascript -e 'set volume output volume 25' -e 'set volume output muted false' && echo '✓ Volume set to 25%.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Set Volume to 75%",
            subtitle: "Raise system audio to a comfortable level",
            icon: "speaker.wave.2.fill", iconColorHex: "#14b8a6", category: .audio,
            keywords: ["volume 75", "loud", "high volume", "volume up",
                       "increase volume", "raise volume"],
            command: .shell("osascript -e 'set volume output volume 75' -e 'set volume output muted false' && echo '✓ Volume set to 75%.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Toggle Do Not Disturb",
            subtitle: "Toggle Focus mode via Shortcuts (requires DND shortcut setup)",
            icon: "moon.zzz.fill", iconColorHex: "#14b8a6", category: .audio,
            keywords: ["do not disturb", "dnd", "focus mode", "notifications off",
                       "silence notifications", "focus", "quiet mode"],
            command: .shell("""
                shortcuts run "Toggle Do Not Disturb" 2>/dev/null && echo "✓ Do Not Disturb toggled." || echo "⚠ Create a 'Toggle Do Not Disturb' shortcut in Shortcuts.app first. Open Shortcuts → New → add 'Set Focus' action → name it 'Toggle Do Not Disturb'."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        // ── System Junk Cleanup (F-033) ─────────────────────────────────

        ActionItem(
            name: "Remove ._ Resource Fork Files",
            subtitle: "Delete macOS resource fork files (created on non-Mac volumes)",
            icon: "doc.badge.xmark", iconColorHex: "#22d97a", category: .system,
            keywords: ["resource forks", "dot underscore", "._files", "AppleDouble",
                       "resource fork", "usb cleanup", "external drive cleanup"],
            command: .shell("""
                echo "Scanning for ._ files…"
                COUNT=$(find ~ -maxdepth 5 -name "._*" -type f 2>/dev/null | wc -l | tr -d ' ')
                find ~ -maxdepth 5 -name "._*" -type f -delete 2>/dev/null
                echo "✓ Removed $COUNT resource fork files."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Font Caches",
            subtitle: "Reset system font caches to fix rendering issues (requires admin)",
            icon: "textformat", iconColorHex: "#22d97a", category: .system,
            keywords: ["font cache", "font rendering", "clear fonts", "atsutil",
                       "font display", "corrupt fonts", "font fix"],
            command: .shell("atsutil databases -remove 2>/dev/null; atsutil server -shutdown 2>/dev/null; atsutil server -ping 2>/dev/null; echo '✓ Font caches cleared. Restart apps to see effect.'"),
            requiresPrivilege: true, isBuiltIn: true),

        ActionItem(
            name: "Clear User Logs",
            subtitle: "Remove all log files from ~/Library/Logs",
            icon: "doc.text.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["user logs", "clear logs", "delete logs", "log files",
                       "library logs", "app logs", "diagnostic logs"],
            command: .shell("""
                SIZE=$(du -sh ~/Library/Logs 2>/dev/null | cut -f1)
                rm -rf ~/Library/Logs/* 2>/dev/null
                echo "✓ User logs cleared (was ~$SIZE)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Remove Broken Symlinks",
            subtitle: "Find and delete dead symbolic links in your home directory",
            icon: "link.badge.xmark", iconColorHex: "#22d97a", category: .system,
            keywords: ["broken symlinks", "dead links", "symbolic links", "dangling links",
                       "stale symlinks", "fix symlinks"],
            command: .shell("""
                echo "Scanning for broken symlinks…"
                COUNT=$(find ~ -maxdepth 4 -type l ! -exec test -e {} \\; -print 2>/dev/null | wc -l | tr -d ' ')
                find ~ -maxdepth 4 -type l ! -exec test -e {} \\; -delete 2>/dev/null
                echo "✓ Removed $COUNT broken symlinks."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Flush QuickLook Cache",
            subtitle: "Reset QuickLook preview cache to fix stale thumbnails",
            icon: "eye.circle.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["quicklook", "quick look", "preview cache", "thumbnail cache",
                       "qlmanage", "stale thumbnails", "finder preview"],
            command: .shell("qlmanage -r cache 2>/dev/null && echo '✓ QuickLook cache flushed.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Rebuild Launch Services Database",
            subtitle: "Fix 'Open With' menu showing duplicate or missing apps",
            icon: "arrow.triangle.2.circlepath.circle.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["launch services", "open with", "duplicate apps", "lsregister",
                       "fix open with", "app associations", "file associations"],
            command: .shell("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user 2>/dev/null && echo '✓ Launch Services database rebuilt. Restart Finder to see changes.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Kill All Background Apps",
            subtitle: "Quit hidden non-background-only apps to free RAM",
            icon: "xmark.app.fill", iconColorHex: "#22d97a", category: .system,
            keywords: ["kill background", "quit hidden", "close background apps",
                       "free ram", "background processes", "hidden apps"],
            command: .shell("""
                osascript -e '
                tell application "System Events"
                    set appList to name of every application process whose visible is false and background only is false
                    repeat with appName in appList
                        try
                            if appName is not "Finder" and appName is not "Halo" then
                                tell application appName to quit
                            end if
                        end try
                    end repeat
                    return (count of appList) - 2 as text
                end tell
                ' 2>/dev/null | xargs -I{} echo "✓ Quit {} hidden background app(s)."
                """),
            requiresPrivilege: false, isBuiltIn: true),

        // ── Developer Cache Cleanup (F-033) ─────────────────────────────

        ActionItem(
            name: "Clear CocoaPods Cache",
            subtitle: "Remove all cached pod specs and downloads",
            icon: "shippingbox.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["cocoapods", "pods", "pod cache", "clear pods",
                       "ios cache", "cocoapods cache", "pod install"],
            command: .shell("pod cache clean --all 2>/dev/null && echo '✓ CocoaPods cache cleared.' || echo '⚠ CocoaPods not installed. Install with: sudo gem install cocoapods'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Gradle Cache",
            subtitle: "Delete ~/.gradle/caches to fix Android build issues",
            icon: "shippingbox.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["gradle", "gradle cache", "android cache", "android studio",
                       "clear gradle", "build cache", "java cache"],
            command: .shell("""
                if [ -d ~/.gradle/caches ]; then
                    SIZE=$(du -sh ~/.gradle/caches 2>/dev/null | cut -f1)
                    rm -rf ~/.gradle/caches
                    echo "✓ Gradle cache cleared (was ~$SIZE)."
                else
                    echo "ℹ No Gradle cache found at ~/.gradle/caches"
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Docker System Prune",
            subtitle: "Remove unused Docker images, containers, and build cache",
            icon: "shippingbox.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["docker", "docker prune", "docker cache", "docker images",
                       "docker cleanup", "container cache", "docker system"],
            command: .shell("docker system prune -f 2>/dev/null && echo '✓ Docker unused images/containers removed.' || echo '⚠ Docker is not running or not installed.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear pip Cache",
            subtitle: "Purge the Python pip package download cache",
            icon: "shippingbox.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["pip", "pip cache", "python cache", "pip3",
                       "python packages", "pip purge"],
            command: .shell("pip3 cache purge 2>/dev/null && echo '✓ pip cache cleared.' || pip cache purge 2>/dev/null && echo '✓ pip cache cleared.' || echo '⚠ pip not found.'"),
            requiresPrivilege: false, isBuiltIn: true),

        ActionItem(
            name: "Clear Homebrew Cache",
            subtitle: "Remove downloaded packages and old formula versions",
            icon: "shippingbox.fill", iconColorHex: "#f97316", category: .developer,
            keywords: ["homebrew", "brew", "brew cache", "brew cleanup",
                       "homebrew cache", "brew packages"],
            command: .shell("""
                if which brew > /dev/null 2>&1; then
                    brew cleanup -s 2>/dev/null
                    CACHE=$(brew --cache 2>/dev/null)
                    if [ -n "$CACHE" ] && [ -d "$CACHE" ]; then
                        SIZE=$(du -sh "$CACHE" 2>/dev/null | cut -f1)
                        rm -rf "$CACHE"
                        echo "✓ Homebrew cache cleared (was ~$SIZE)."
                    else
                        echo "✓ Homebrew cleanup complete."
                    fi
                else
                    echo "⚠ Homebrew not installed."
                fi
                """),
            requiresPrivilege: false, isBuiltIn: true),
    ]
    // swiftlint:enable line_length
}
