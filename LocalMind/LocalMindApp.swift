//
//  LocalMindApp.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI

@main
struct LocalMindApp: App {
    @State private var sharedAIManager = AIServiceManager()
    @State private var sharedDataStore = DataStore()
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @AppStorage("enableGlobalShortcut") private var enableGlobalShortcut: Bool = false

    init() {
        // Register the AppStorage default so a fresh install reads `true` here
        // instead of UserDefaults's bool fallback of `false`.
        UserDefaults.standard.register(defaults: ["isDarkMode": true])
        let isDark = UserDefaults.standard.bool(forKey: "isDarkMode")
        NSApplication.shared.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
    
    var body: some Scene {
        // WindowGroup so ⌘N opens a fresh window. The first window still
        // restores its position via SwiftUI's built-in scene restoration.
        WindowGroup("LocalMind", id: "main") {
            ContentView(aiManager: sharedAIManager, dataStore: sharedDataStore)
                .frame(minWidth: AppTheme.Dimensions.minWindowWidth, minHeight: AppTheme.Dimensions.minWindowHeight)
                .background(AppTheme.Colors.backgroundPrimary)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onAppear {
                    applyAppearance(isDarkMode)
                    BubbleWindowController.shared.setup(aiManager: sharedAIManager, dataStore: sharedDataStore)

                    HotkeyManager.shared.onHotkeyPressed = {
                        BubbleWindowController.shared.toggle()
                    }
                    if enableGlobalShortcut {
                        HotkeyManager.shared.registerHotkey()
                        HotkeyManager.shared.requestPermissions()
                    }
                }
                .onChange(of: isDarkMode) { _, newValue in
                    applyAppearance(newValue)
                }
                .onChange(of: enableGlobalShortcut) { _, isEnabled in
                    if isEnabled {
                        HotkeyManager.shared.registerHotkey()
                        HotkeyManager.shared.requestPermissions()
                    } else {
                        HotkeyManager.shared.unregisterHotkey()
                    }
                }
        }
        .commands {
            SidebarCommands()
        }
        
        Settings {
            SettingsView(aiManager: sharedAIManager, dataStore: sharedDataStore)
                .preferredColorScheme(isDarkMode ? .dark : .light)
        }
        
        // Use the label initializer so we can attach a tooltip (.help) to the icon
        MenuBarExtra {
            QuickActionPanel(aiManager: sharedAIManager, dataStore: sharedDataStore)
                .preferredColorScheme(isDarkMode ? .dark : .light)
        } label: {
            // .renderingMode(.original) opts out of the template invert so the
            // icon stays white regardless of menu bar or system appearance.
            Image(systemName: "brain.head.profile")
                .renderingMode(.original)
                .foregroundStyle(.white)
                .help("LocalMind")
        }
        .menuBarExtraStyle(.window)
    }

    /// Sync `NSApp.appearance` with the user's preference so the dynamic
    /// NSColors in Theme.swift (which gate on `NSColor.darkAqua`) match
    /// SwiftUI's environment. Without this, MenuBarExtra and floating
    /// panels render in the system appearance instead of the app's.
    private func applyAppearance(_ dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        // MenuBarExtra and floating panels cache appearance on first show;
        // explicitly push it to every existing window so they re-render.
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}
