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
    @State private var sharedProfileStore = ProfileStore()
    @State private var sharedMCPService: MCPService?
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
            Group {
                if sharedProfileStore.isSignedIn {
                    ContentView(
                        aiManager: sharedAIManager,
                        dataStore: sharedDataStore,
                        profileStore: sharedProfileStore
                    )
                } else {
                    SignInView(profileStore: sharedProfileStore)
                }
            }
                .frame(minWidth: AppTheme.Dimensions.minWindowWidth, minHeight: AppTheme.Dimensions.minWindowHeight)
                .background(AppTheme.Colors.backgroundPrimary)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onAppear {
                    applyAppearance(isDarkMode)
                    let mcpService = MCPService(dataStore: sharedDataStore)
                    sharedMCPService = mcpService
                    sharedAIManager.setMCPService(mcpService)
                    BubbleWindowController.shared.setup(aiManager: sharedAIManager, dataStore: sharedDataStore)

                    // Hand the data store a one-time migration hook so the
                    // first profile adopts pre-existing (pre-profiles) chats.
                    let dataStoreRef = sharedDataStore
                    sharedProfileStore.onFirstProfileCreated = { firstProfileID in
                        dataStoreRef.claimOrphanConversations(forProfile: firstProfileID)
                    }

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
            SettingsView(
                aiManager: sharedAIManager,
                dataStore: sharedDataStore,
                mcpService: sharedMCPService,
                profileStore: sharedProfileStore
            )
                .preferredColorScheme(isDarkMode ? .dark : .light)
        }
        
        // Use the label initializer so we can attach a tooltip (.help) to the icon
        MenuBarExtra {
            QuickActionPanel(aiManager: sharedAIManager, dataStore: sharedDataStore)
                .preferredColorScheme(isDarkMode ? .dark : .light)
        } label: {
            // We build a real NSImage (rather than `Image(systemName:)`) so we
            // can flip `isTemplate = false`. Template images get inverted by
            // the menu bar based on its current appearance — that's what was
            // making the icon black on a light menu bar. With `isTemplate = false`
            // and a baked-in white palette colour, macOS leaves the bitmap alone.
            if let nsImage = LocalMindApp.whiteMenuBarIcon() {
                Image(nsImage: nsImage)
                    .help("LocalMind")
            } else {
                Image(systemName: "brain.head.profile")
                    .help("LocalMind")
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// Builds an always-white "brain.head.profile" symbol for the menu bar.
    /// Calling `.isTemplate = false` is the key step — without it, macOS
    /// repaints the symbol based on menu-bar appearance, flipping to black
    /// on light menu bars.
    static func whiteMenuBarIcon() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "LocalMind")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
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
