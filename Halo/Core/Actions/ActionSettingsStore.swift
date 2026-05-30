import SwiftUI

// MARK: - ActionSettingsStore

/// Persists which actions are enabled in the Quick Actions panel, the keyboard
/// shortcut for the picker, and the voice-search toggle.
/// Singleton — observed by ActionLibrary, ActionSettingsTab, and QuickActionPickerController.
@MainActor
final class ActionSettingsStore: ObservableObject {

    static let shared = ActionSettingsStore()

    // MARK: - Keys

    private enum Keys {
        static let enabled   = "actionEnabledKeys"      // [String] in UserDefaults
        static let keyCode   = "actionPickerKeyCode"    // Int
        static let modifiers = "actionPickerModifiers"  // Int
        static let voice     = "actionVoiceSearchEnabled"
    }

    // MARK: - Published state

    /// Stable keys of currently-enabled actions. Nil = first launch, use defaults.
    @Published private(set) var enabledKeys: Set<String>

    /// Keyboard shortcut for ⌘⇧A (action picker). Matches HotkeyManager.
    @Published var shortcutKeyCode:   Int { didSet { saveShortcut() } }
    @Published var shortcutModifiers: Int { didSet { saveShortcut() } }

    /// Whether the microphone voice-search button is shown in the picker.
    @Published var voiceSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(voiceSearchEnabled, forKey: Keys.voice) }
    }

    // MARK: - Init

    private init() {
        // Keyboard shortcut — default ⌘⇧A
        shortcutKeyCode   = UserDefaults.standard.object(forKey: Keys.keyCode) as? Int ?? 0   // A
        shortcutModifiers = UserDefaults.standard.object(forKey: Keys.modifiers) as? Int
                            ?? Int(NSEvent.ModifierFlags([.command, .shift]).rawValue)

        voiceSearchEnabled = UserDefaults.standard.bool(forKey: Keys.voice)

        // Enabled keys — nil array means first launch → use defaults
        if let saved = UserDefaults.standard.array(forKey: Keys.enabled) as? [String] {
            enabledKeys = Set(saved)
        } else {
            enabledKeys = ActionSettingsStore.defaultEnabledKeys
        }
    }

    // MARK: - Default enabled set

    /// The subset shown out-of-the-box — universally useful, not overwhelming.
    /// All 15 shipped v2.2 actions are on by default.
    static let defaultEnabledKeys: Set<String> = [
        // Xcode
        "xcode.clear_derived_data",
        "xcode.clear_spm_cache",
        "xcode.reset_ios_simulators",
        "xcode.kill_xcode",
        // System
        "system.flush_dns_cache",
        "system.purge_inactive_ram",
        "system.empty_trash",
        "system.rebuild_spotlight_index",
        "system.repair_disk_permissions",
        // Network
        "network.run_speed_test",
        "network.check_connectivity",
        "network.show_network_interfaces",
        // Halo
        "halo.run_smart_scan",
        "halo.export_health_report",
        "halo.clear_clipboard_history",
    ]

    // MARK: - Mutations

    func setEnabled(_ enabled: Bool, for key: String) {
        if enabled { enabledKeys.insert(key) } else { enabledKeys.remove(key) }
        save()
    }

    func isEnabled(_ key: String) -> Bool {
        enabledKeys.contains(key)
    }

    func enableAll()   { enabledKeys = Set(ActionLibrary.shared.actions.map(\.stableKey)); save() }
    func disableAll()  { enabledKeys = []; save() }
    func resetToDefaults() { enabledKeys = ActionSettingsStore.defaultEnabledKeys; save() }

    func enableCategory(_ cat: ActionCategory) {
        ActionLibrary.shared.actions
            .filter { $0.category == cat }
            .forEach { enabledKeys.insert($0.stableKey) }
        save()
    }

    func disableCategory(_ cat: ActionCategory) {
        ActionLibrary.shared.actions
            .filter { $0.category == cat }
            .forEach { enabledKeys.remove($0.stableKey) }
        save()
    }

    // MARK: - Shortcut

    func updateShortcut(keyCode: Int, modifiers: Int) {
        shortcutKeyCode   = keyCode
        shortcutModifiers = modifiers
    }

    private func saveShortcut() {
        UserDefaults.standard.set(shortcutKeyCode,   forKey: Keys.keyCode)
        UserDefaults.standard.set(shortcutModifiers, forKey: Keys.modifiers)
    }

    // MARK: - Persistence

    private func save() {
        UserDefaults.standard.set(Array(enabledKeys), forKey: Keys.enabled)
    }
}
