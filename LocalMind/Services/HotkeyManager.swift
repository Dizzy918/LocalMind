//
//  HotkeyManager.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 23.06.26.
//

import AppKit
import Carbon

class HotkeyManager {
    static let shared = HotkeyManager()
    
    var onHotkeyPressed: (() -> Void)?
    
    private var hotKeyRef: EventHotKeyRef?
    
    private init() {}
    
    func registerHotkey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType("LMND".utf8.reduce(0) { $0 << 8 + numericCast($1) })
        hotKeyID.id = 1
        
        // kVK_Space is 49. Option key is optionKey (or cmdKey/controlKey etc)
        // Option is 58 in Carbon, modifier is optionKey
        let keyCode: UInt32 = 49 // Space
        let modifiers: UInt32 = UInt32(optionKey)
        
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, theEvent, userData) -> OSStatus in
            let mySelf = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
            mySelf.onHotkeyPressed?()
            return noErr
        }, 1, &eventType, ptr, nil)
        
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
    
    func requestPermissions() {
        // Request Accessibility
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        

    }
}
