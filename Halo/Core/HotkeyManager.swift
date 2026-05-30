import AppKit

// Registers a configurable global/local hotkey for the clipboard quick picker.
// Local monitor fires when Halo is focused (no Accessibility needed).
// Global monitor fires from any app — only registered when AXIsProcessTrusted() is true.
// Call registerGlobalMonitor() again after the user grants Accessibility permission.
@MainActor
final class HotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Clipboard shortcut — default ⌘⇧V
    var onClipboardShortcut: (() -> Void)?
    private(set) var keyCode:   UInt16                = 9                       // V
    private(set) var modifiers: NSEvent.ModifierFlags = [.command, .shift]      // ⌘⇧

    // Actions shortcut — configurable; stored in ActionSettingsStore
    var onActionShortcut: (() -> Void)?
    private(set) var actionKeyCode:   UInt16                = 0                 // A (default)
    private(set) var actionModifiers: NSEvent.ModifierFlags = [.command, .shift] // ⌘⇧

    // MARK: - Public API

    func start(keyCode: UInt16 = 9, modifiers: NSEvent.ModifierFlags = [.command, .shift]) {
        stop()
        self.keyCode   = keyCode
        self.modifiers = modifiers

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == self.modifiers && event.keyCode == self.keyCode {
                DispatchQueue.main.async { self.onClipboardShortcut?() }
                return nil
            }
            if flags == self.actionModifiers && event.keyCode == self.actionKeyCode {
                DispatchQueue.main.async { self.onActionShortcut?() }
                return nil
            }
            return event
        }

        registerGlobalMonitor()
    }

    // Call this after the user grants Accessibility in System Settings.
    func registerGlobalMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        guard AXIsProcessTrusted() else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == self.modifiers && event.keyCode == self.keyCode {
                DispatchQueue.main.async { self.onClipboardShortcut?() }
            } else if flags == self.actionModifiers && event.keyCode == self.actionKeyCode {
                DispatchQueue.main.async { self.onActionShortcut?() }
            }
        }
    }

    /// Called when the user records a new action-picker shortcut in Settings.
    /// Re-registers monitors with the new key combination.
    func updateActionShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        actionKeyCode   = keyCode
        actionModifiers = modifiers
        // Re-register monitors so the new key takes effect immediately
        start(keyCode: self.keyCode, modifiers: self.modifiers)
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor  = nil
    }

    // MARK: - Display helpers

    static func displayString(keyCode: Int, modifiers: Int) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += keyCodeChar(keyCode)
        return s
    }

    private static func keyCodeChar(_ code: Int) -> String {
        let map: [Int: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X",
            8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R",
            16:"Y", 17:"T", 31:"O", 32:"U", 34:"I", 35:"P",
            37:"L", 38:"J", 40:"K", 45:"N", 46:"M",
            18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5",
            25:"9", 26:"7", 28:"8", 29:"0",
            36:"↩", 48:"⇥", 49:"Space", 51:"⌫", 53:"⎋",
            123:"←", 124:"→", 125:"↓", 126:"↑"
        ]
        return map[code] ?? "?"
    }
}
