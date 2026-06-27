//
//  HotkeyManager.swift
//  LocalMind
//

import AppKit
import Carbon

final class HotkeyManager {
    static let shared = HotkeyManager()

    var onHotkeyPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private static let keyCodeDefaultsKey = "hotkey.keyCode"
    private static let modifiersDefaultsKey = "hotkey.modifiers"
    static let defaultKeyCode: UInt32 = 49     // Space
    static let defaultModifiers: UInt32 = UInt32(optionKey)

    private init() {}

    var currentKeyCode: UInt32 {
        let stored = UserDefaults.standard.integer(forKey: Self.keyCodeDefaultsKey)
        return stored == 0 ? Self.defaultKeyCode : UInt32(stored)
    }

    var currentModifiers: UInt32 {
        let stored = UserDefaults.standard.integer(forKey: Self.modifiersDefaultsKey)
        return stored == 0 ? Self.defaultModifiers : UInt32(stored)
    }

    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeDefaultsKey)
        UserDefaults.standard.set(Int(modifiers), forKey: Self.modifiersDefaultsKey)
        if hotKeyRef != nil { registerHotkey() }
    }

    func resetHotkey() {
        UserDefaults.standard.removeObject(forKey: Self.keyCodeDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.modifiersDefaultsKey)
        if hotKeyRef != nil { registerHotkey() }
    }

    func unregisterHotkey() {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
    }

    func registerHotkey() {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType("LMND".utf8.reduce(0) { $0 << 8 + numericCast($1) })
        hotKeyID.id = 1

        if eventHandler == nil {
            var eventType = EventTypeSpec()
            eventType.eventClass = OSType(kEventClassKeyboard)
            eventType.eventKind = OSType(kEventHotKeyPressed)
            let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
                let mySelf = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
                mySelf.onHotkeyPressed?()
                return noErr
            }, 1, &eventType, ptr, &eventHandler)
        }

        RegisterEventHotKey(currentKeyCode, currentModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Human-readable description of the current shortcut, e.g. "⌥ Space".
    func currentShortcutDescription() -> String {
        Self.describe(keyCode: currentKeyCode, modifiers: currentModifiers)
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0  { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0   { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0     { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined(separator: " ")
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Esc"
        case 51: return "Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            if let name = letterOrDigit(for: keyCode) { return name }
            return "Key \(keyCode)"
        }
    }

    private static func letterOrDigit(for keyCode: UInt32) -> String? {
        let map: [Int: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
            12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
            16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
            26: "7", 28: "8", 25: "9"
        ]
        return map[Int(keyCode)]
    }
}

/// NSView that captures the next key combination the user presses and returns it.
/// Embedded inside SwiftUI via NSViewRepresentable for the shortcut recorder UI.
final class ShortcutRecorderView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.carbonFlags
        let keyCode = UInt32(event.keyCode)
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }
        onCapture?(keyCode, modifiers)
    }
}

private extension NSEvent.ModifierFlags {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command)  { flags |= UInt32(cmdKey) }
        if contains(.option)   { flags |= UInt32(optionKey) }
        if contains(.control)  { flags |= UInt32(controlKey) }
        if contains(.shift)    { flags |= UInt32(shiftKey) }
        return flags
    }
}
