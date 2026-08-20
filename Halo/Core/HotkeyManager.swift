import AppKit
import Carbon.HIToolbox

// Registers Halo's global hotkeys via the Carbon Event Manager
// (RegisterEventHotKey), NOT NSEvent local/global monitors.
//
// Why: NSEvent.addGlobalMonitorForEvents only fires while Halo is NOT the
// focused app, but only if AXIsProcessTrusted() — i.e. the user has granted
// Accessibility permission. Without it, only the local monitor fires,
// which only catches the key while Halo itself is frontmost — exactly the
// bug this replaces ("picker only works when Halo is focused"). Carbon
// hotkeys are true system-wide key registrations: they fire regardless of
// which app is frontmost and need no Accessibility permission at all —
// this is the same mechanism long used by Spotlight-alternative launchers
// (Alfred, Raycast-era tools) for exactly this reason.
@MainActor
final class HotkeyManager {

    private enum Slot: UInt32, CaseIterable {
        case clipboard = 1
        case action = 2
        case ai = 3
        case driveSearch = 4
    }

    /// Four-char-code signature identifying Halo's hotkeys to the system.
    private static let signature: OSType = 0x48414C4F // 'HALO'

    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    // Clipboard shortcut — default ⌘⇧V
    var onClipboardShortcut: (() -> Void)?
    private(set) var keyCode:   UInt16                = 9                       // V
    private(set) var modifiers: NSEvent.ModifierFlags = [.command, .shift]      // ⌘⇧

    // Actions shortcut — configurable; stored in ActionSettingsStore
    var onActionShortcut: (() -> Void)?
    private(set) var actionKeyCode:   UInt16                = 0                 // A (default)
    private(set) var actionModifiers: NSEvent.ModifierFlags = [.command, .shift] // ⌘⇧

    // AI quick-ask shortcut — default ⌘⇧I (F-046 quick-ask overlay)
    var onAIShortcut: (() -> Void)?
    private(set) var aiKeyCode:   UInt16                = 34                    // I (default)
    private(set) var aiModifiers: NSEvent.ModifierFlags = [.command, .shift]    // ⌘⇧

    // Drive search shortcut — default ⌘⇧F (F-051 quick search picker)
    var onDriveSearchShortcut: (() -> Void)?
    private(set) var driveSearchKeyCode:   UInt16                = 3                     // F (default)
    private(set) var driveSearchModifiers: NSEvent.ModifierFlags = [.command, .shift]    // ⌘⇧

    // MARK: - Public API

    func start(keyCode: UInt16 = 9, modifiers: NSEvent.ModifierFlags = [.command, .shift]) {
        self.keyCode   = keyCode
        self.modifiers = modifiers
        installEventHandlerIfNeeded()
        registerAll()
    }

    /// Kept for call-site compatibility (AppState calls this after an
    /// Accessibility-trust change) — now a harmless re-register, since
    /// Carbon hotkeys never depended on that permission to begin with.
    func registerGlobalMonitor() {
        registerAll()
    }

    /// Called when the user records a new AI quick-ask shortcut.
    func updateAIShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        aiKeyCode   = keyCode
        aiModifiers = modifiers
        registerAll()
    }

    /// Called when the user records a new action-picker shortcut in Settings.
    func updateActionShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        actionKeyCode   = keyCode
        actionModifiers = modifiers
        registerAll()
    }

    func stop() {
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    // MARK: - Carbon plumbing

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async { manager.handleHotKey(id: id) }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandlerRef)
    }

    private func handleHotKey(id: UInt32) {
        switch Slot(rawValue: id) {
        case .clipboard:   onClipboardShortcut?()
        case .action:      onActionShortcut?()
        case .ai:          onAIShortcut?()
        case .driveSearch: onDriveSearchShortcut?()
        case nil:          break
        }
    }

    private func registerAll() {
        register(.clipboard, keyCode: keyCode, modifiers: modifiers)
        register(.action, keyCode: actionKeyCode, modifiers: actionModifiers)
        register(.ai, keyCode: aiKeyCode, modifiers: aiModifiers)
        register(.driveSearch, keyCode: driveSearchKeyCode, modifiers: driveSearchModifiers)
    }

    private func register(_ slot: Slot, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        if let existing = hotKeyRefs.removeValue(forKey: slot) {
            UnregisterEventHotKey(existing)
        }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), carbonModifiers(from: modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr, let hotKeyRef {
            hotKeyRefs[slot] = hotKeyRef
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
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
