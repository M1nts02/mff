import Cocoa
import Carbon.HIToolbox

// MARK: - Global hotkey

/// A system-wide hotkey registered via Carbon's `RegisterEventHotKey`, which
/// (unlike `NSEvent` global monitors) works without accessibility permission for
/// key combinations that no app consumes. Fires a callback on the main queue.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private let callback: () -> Void

    /// Parses a keybinding like "cmd+space", "ctrl+alt+k", "cmd+shift+p".
    /// Returns nil for an empty or unparseable string.
    static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = spec.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            case "alt", "opt", "option", "⌥": modifiers |= UInt32(optionKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard let code = keyCode(for: keyName) else { return nil }
        return (code, modifiers)
    }

    private static func keyCode(for name: String) -> UInt32? {
        let named: [String: Int] = [
            "space": kVK_Space,
            "return": kVK_Return, "enter": kVK_Return,
            "tab": kVK_Tab,
            "escape": kVK_Escape, "esc": kVK_Escape,
            "delete": kVK_Delete, "backspace": kVK_Delete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
            "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12
        ]
        if let code = named[name] { return UInt32(code) }
        // Single character: US-layout key codes (physical keys). A keybinding
        // is a physical shortcut, so other layouts keep the same positions.
        if name.count == 1, let scalar = name.unicodeScalars.first, scalar.value < 128 {
            let keyCodes: [Character: Int] = [
                "a": kVK_ANSI_A, "s": kVK_ANSI_S, "d": kVK_ANSI_D, "f": kVK_ANSI_F,
                "h": kVK_ANSI_H, "g": kVK_ANSI_G, "z": kVK_ANSI_Z, "x": kVK_ANSI_X,
                "c": kVK_ANSI_C, "v": kVK_ANSI_V, "b": kVK_ANSI_B, "q": kVK_ANSI_Q,
                "w": kVK_ANSI_W, "e": kVK_ANSI_E, "r": kVK_ANSI_R, "y": kVK_ANSI_Y,
                "t": kVK_ANSI_T, "o": kVK_ANSI_O, "u": kVK_ANSI_U, "i": kVK_ANSI_I,
                "p": kVK_ANSI_P, "l": kVK_ANSI_L, "j": kVK_ANSI_J, "k": kVK_ANSI_K,
                "n": kVK_ANSI_N, "m": kVK_ANSI_M
            ]
            return keyCodes[Character(name)] .map { UInt32($0) }
        }
        return nil
    }

    /// Registers a hotkey. Returns nil if the spec is invalid or the system
    /// refuses the combination (already taken by another app).
    init?(spec: String, callback: @escaping () -> Void) {
        guard let parsed = HotKey.parse(spec) else { return nil }
        self.callback = callback
        self.id = HotKey.nextID
        HotKey.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let userData {
                let handler = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                // Match by id so a stale registration is ignored.
                if handler.id == hkID.id {
                    DispatchQueue.main.async { handler.callback() }
                }
            }
            return noErr
        }, 1, &eventType, selfPtr, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x6D666B00), id: id) // 'mfk\0'
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.handlers[id] = self
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    deinit { unregister() }
}
