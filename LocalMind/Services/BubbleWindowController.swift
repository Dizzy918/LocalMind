//
//  BubbleWindowController.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 23.06.26.
//

import AppKit
import SwiftUI

class BubbleWindowController: NSWindowController {
    static let shared = BubbleWindowController()
    
    private var isVisible = false
    
    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.nonactivatingPanel, .hudWindow, .resizable, .titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        let alwaysOnTop = UserDefaults.standard.bool(forKey: "bubbleWindowAlwaysOnTop")
        window.level = alwaysOnTop ? .floating : .normal
        // .transient + .ignoresCycle keep this out of the Cmd+Tab app switcher.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)
    }

    private func positionAtBottom() {
        guard let window = window, let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let x = screenRect.midX - (window.frame.width / 2)
        let y = screenRect.minY + 80
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setup(aiManager: AIServiceManager, dataStore: DataStore) {
        let rootView = BubbleView(aiManager: aiManager, dataStore: dataStore, onClose: { [weak self] in
            self?.hide()
        })
        window?.contentView = NSHostingView(rootView: rootView)
    }
    
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }
    
    func show() {
        positionAtBottom()
        window?.orderFrontRegardless()
        window?.makeKey()
        isVisible = true
    }
    
    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
    
    func updateWindowLevel() {
        let alwaysOnTop = UserDefaults.standard.bool(forKey: "bubbleWindowAlwaysOnTop")
        window?.level = alwaysOnTop ? .floating : .normal
    }
}
