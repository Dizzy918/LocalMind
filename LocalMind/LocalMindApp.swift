//
//  LocalMindApp.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI

extension Notification.Name {
    /// Posted by the ⌘N menu command; ContentView starts a fresh conversation.
    static let newConversation = Notification.Name("LocalMind.newConversation")
    /// Posted with a conversation UUID as the object; ContentView selects it.
    /// Used by the Agent Team panel's "Open as chat" to hand off a saved run.
    static let openConversation = Notification.Name("LocalMind.openConversation")
}

@main
struct LocalMindApp: App {
    @State private var sharedAIManager: AIServiceManager
    @State private var sharedDataStore: DataStore
    @State private var sharedGenerationService: ChatGenerationService
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

        // The generation service outlives any single view so answers keep
        // streaming when the user switches conversations — it needs the same
        // store/manager instances the views get.
        let aiManager = AIServiceManager()
        let dataStore = DataStore()
        _sharedAIManager = State(initialValue: aiManager)
        _sharedDataStore = State(initialValue: dataStore)
        _sharedGenerationService = State(initialValue: ChatGenerationService(dataStore: dataStore, aiManager: aiManager))
    }

    /// Handles localmind:// URLs — the app's automation surface (Shortcuts,
    /// scripts, other apps). Supported:
    ///   localmind://new                          — start a blank conversation
    ///   localmind://ask?prompt=…&agent=Coder     — ask (optionally via an agent)
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "localmind",
              sharedProfileStore.isSignedIn else { return }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        NSApp.activate(ignoringOtherApps: true)

        switch url.host?.lowercased() ?? "ask" {
        case "new":
            NotificationCenter.default.post(name: .newConversation, object: nil)

        case "ask":
            let prompt = (value("prompt") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                NotificationCenter.default.post(name: .newConversation, object: nil)
                return
            }
            var conversation = Conversation(
                title: String(prompt.prefix(50)) + (prompt.count > 50 ? "..." : ""),
                messages: [ChatMessage(role: .user, content: prompt)]
            )
            if let agentName = value("agent"),
               let agent = sharedDataStore.agents.first(where: {
                   $0.name.caseInsensitiveCompare(agentName) == .orderedSame
               }) {
                conversation.agentID = agent.id
                conversation.emoji = agent.emoji
            }
            sharedDataStore.saveConversation(conversation)
            NotificationCenter.default.post(name: .openConversation, object: conversation.id)
            sharedGenerationService.start(conversationID: conversation.id)

        default:
            break
        }
    }
    
    var body: some Scene {
        WindowGroup("LocalMind", id: "main") {
            Group {
                if sharedProfileStore.isSignedIn {
                    ContentView(
                        aiManager: sharedAIManager,
                        dataStore: sharedDataStore,
                        profileStore: sharedProfileStore,
                        generationService: sharedGenerationService
                    )
                } else {
                    SignInView(profileStore: sharedProfileStore)
                }
            }
                .frame(minWidth: AppTheme.Dimensions.minWindowWidth, minHeight: AppTheme.Dimensions.minWindowHeight)
                .background(AppTheme.Colors.backgroundPrimary)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    applyAppearance(isDarkMode)
                    // UI-test hook: land signed in as a guest so smoke tests
                    // skip the sign-in screen on fresh machines.
                    if CommandLine.arguments.contains("--uitest-autosignin"),
                       !sharedProfileStore.isSignedIn {
                        _ = sharedProfileStore.createProfile(displayName: "UI Test", email: "", method: .guest)
                    }
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

                    // Catch up the cross-conversation memory index with chats
                    // that changed while the feature was off or the app closed.
                    if ChatMemoryStore.isEnabled {
                        let conversations = sharedDataStore.conversations
                        Task { await ChatMemoryStore.shared.syncAll(conversations) }
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
            // Replace the default "New Window" (⌘N) with "New Conversation",
            // matching ChatGPT/Claude desktop and what the in-app help claims.
            // The window can't call into ContentView's @State directly, so we
            // bridge through a notification ContentView listens for.
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    NotificationCenter.default.post(name: .newConversation, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
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
