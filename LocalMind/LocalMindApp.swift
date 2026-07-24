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
    /// Posted by ⌘W in the tabbed layout; ContentView closes the active tab.
    static let closeCurrentTab = Notification.Name("LocalMind.closeCurrentTab")
    /// Posted by ⇧⌘T; ContentView reopens the most recently closed tab.
    static let reopenClosedTab = Notification.Name("LocalMind.reopenClosedTab")
    /// Posted by ⌘T; ContentView raises the searchable conversation picker.
    static let showTabPicker = Notification.Name("LocalMind.showTabPicker")
}

/// Adds "New Window" back to the File menu.
///
/// Lives in its own `Commands` type because it needs `@Environment(\.openWindow)`,
/// which only resolves inside a `Commands`/`View` body — the app's `.commands`
/// closure has no environment of its own.
struct NewWindowCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

/// Receives "Ask LocalMind" from the system Services menu (selected text in
/// any app). Registered as `NSApp.servicesProvider`; the NSMessage in
/// Config/Info.plist maps to `askLocalMind:userData:error:`.
final class ServicesProvider: NSObject {
    var onAsk: ((String) -> Void)?

    @objc func askLocalMind(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        onAsk?(text)
    }
}

@main
struct LocalMindApp: App {
    @State private var sharedAIManager: AIServiceManager
    @State private var sharedDataStore: DataStore
    @State private var sharedGenerationService: ChatGenerationService
    @State private var sharedScheduleService: ScheduleService
    @State private var sharedProfileStore = ProfileStore()
    @State private var sharedMCPService: MCPService?
    @State private var servicesProvider = ServicesProvider()
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @AppStorage("enableGlobalShortcut") private var enableGlobalShortcut: Bool = false
    // Drives the File menu's labels — ⌘W closes a tab or the window depending
    // on the layout, and the menu should say which.
    @AppStorage(AppLayout.storageKey) private var layoutRaw: String = AppLayout.classic.rawValue
    private var layout: AppLayout { AppLayout(rawValue: layoutRaw) ?? .classic }

    init() {
        // Register the AppStorage default so a fresh install reads `true` here
        // instead of UserDefaults's bool fallback of `false`.
        UserDefaults.standard.register(defaults: ["isDarkMode": true])

        // Always launch with a window.
        //
        // With state restoration on, quitting while the main window is closed
        // makes the next launch restore "no windows" — and because the File
        // menu's New Window item was replaced by New Conversation, there is no
        // way to get one back. The app sits running (the MenuBarExtra keeps it
        // alive) with no UI. Reproduced repeatedly: `open` would activate it
        // but never produce a window.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        let isDark = UserDefaults.standard.bool(forKey: "isDarkMode")
        NSApplication.shared.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        // The generation service outlives any single view so answers keep
        // streaming when the user switches conversations — it needs the same
        // store/manager instances the views get.
        let aiManager = AIServiceManager()
        let dataStore = DataStore()
        let generationService = ChatGenerationService(dataStore: dataStore, aiManager: aiManager)
        _sharedAIManager = State(initialValue: aiManager)
        _sharedDataStore = State(initialValue: dataStore)
        _sharedGenerationService = State(initialValue: generationService)
        _sharedScheduleService = State(initialValue: ScheduleService(dataStore: dataStore, generationService: generationService))
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
            startQuickAsk(prompt: prompt, agentName: value("agent"))

        default:
            break
        }
    }

    /// Shared entry point for external asks (URL scheme, Services menu):
    /// creates a conversation, opens it, and starts generating.
    private func startQuickAsk(prompt: String, agentName: String?) {
        var conversation = Conversation(
            title: String(prompt.prefix(50)) + (prompt.count > 50 ? "..." : ""),
            messages: [ChatMessage(role: .user, content: prompt)]
        )
        if let agentName,
           let agent = sharedDataStore.agents.first(where: {
               $0.name.caseInsensitiveCompare(agentName) == .orderedSame
           }) {
            conversation.agentID = agent.id
            conversation.emoji = agent.emoji
        }
        sharedDataStore.saveConversation(conversation)
        NotificationCenter.default.post(name: .openConversation, object: conversation.id)
        sharedGenerationService.start(conversationID: conversation.id)
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

                    // "Ask LocalMind" in every app's Services menu.
                    servicesProvider.onAsk = { text in
                        guard sharedProfileStore.isSignedIn else { return }
                        NSApp.activate(ignoringOtherApps: true)
                        startQuickAsk(prompt: text, agentName: nil)
                    }
                    NSApp.servicesProvider = servicesProvider
                    NSUpdateDynamicServices()
                    let mcpService = MCPService(dataStore: sharedDataStore)
                    sharedMCPService = mcpService
                    sharedAIManager.setMCPService(mcpService)
                    BubbleWindowController.shared.setup(aiManager: sharedAIManager, dataStore: sharedDataStore, generationService: sharedGenerationService)

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
                Button(layout == .tabbed ? "New Tab" : "New Conversation") {
                    NotificationCenter.default.post(name: .newConversation, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                // Safari's tab shortcuts. In the sidebar layout ⌘W has to keep
                // meaning "close the window" — this item sits above the system's
                // Close item in the File menu, so it wins the binding and has to
                // hand the action back when there are no tabs to close.
                Button(layout == .tabbed ? "Close Tab" : "Close Window") {
                    if AppLayout.current == .tabbed {
                        NotificationCenter.default.post(name: .closeCurrentTab, object: nil)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)

                if layout == .tabbed {
                    Button("Open Conversation…") {
                        NotificationCenter.default.post(name: .showTabPicker, object: nil)
                    }
                    .keyboardShortcut("t", modifiers: .command)

                    Button("Reopen Closed Tab") {
                        NotificationCenter.default.post(name: .reopenClosedTab, object: nil)
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                }
            }

            // Restores the way back to a window. Replacing `.newItem` above
            // removed AppKit's own New Window item, and because the MenuBarExtra
            // keeps the process alive after the last window closes, the app
            // could end up running with no window and no way to open one —
            // state restoration then reopens it that way on the next launch too.
            NewWindowCommand()

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdaterService.shared.checkForUpdates()
                }
            }
        }
        
        Settings {
            SettingsView(
                aiManager: sharedAIManager,
                dataStore: sharedDataStore,
                mcpService: sharedMCPService,
                profileStore: sharedProfileStore,
                scheduleService: sharedScheduleService
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
