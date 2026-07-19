//
//  SettingsView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI
import UniformTypeIdentifiers

/// App settings panel
struct SettingsView: View {
    let aiManager: AIServiceManager
    let dataStore: DataStore
    let mcpService: MCPService?
    let profileStore: ProfileStore
    let scheduleService: ScheduleService

    @State private var selectedTab: SettingsTab = .general
    @State private var importStatus: String = ""
    @State private var confirmingClearHistory = false

    /// Optional deep-link tab. Anything in the app that wants Settings to
    /// land on a specific tab writes the tab's rawValue to this UserDefaults
    /// key BEFORE opening Settings; SettingsView reads it once on appear
    /// and then clears it so the next open isn't pinned to the same tab.
    static let deepLinkTabKey = "settingsDeepLinkTab"
    
    // New AppStorage bindings
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @AppStorage("bubbleWindowAlwaysOnTop") private var bubbleWindowAlwaysOnTop: Bool = false
    @AppStorage("autoReadResponses") private var autoReadResponses: Bool = false
    @AppStorage("enableGlobalShortcut") private var enableGlobalShortcut: Bool = false
    @AppStorage("defaultSystemPrompt") private var defaultSystemPrompt: String = "You are LocalMind, a helpful, concise AI assistant. Provide clear, actionable responses. Use markdown formatting when appropriate."
    @AppStorage("contextMessageLimit") private var contextMessageLimit: Int = 10
    @AppStorage("rememberPastChats") private var rememberPastChats: Bool = false
    @State private var memoryEntryCount = 0
    
    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case profile = "Profile"
        case providers = "Providers"
        case chat = "Chat"
        case data = "Data"
        case agents = "Agents"
        case automations = "Automations"
        case customTools = "Tools"
        case mcp = "MCP"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "gear"
            case .profile: return "person.crop.circle"
            case .providers: return "network"
            case .chat: return "message"
            case .data: return "lock.shield"
            case .agents: return "person.3"
            case .automations: return "clock.badge"
            case .customTools: return "hammer"
            case .mcp: return "server.rack"
            case .about: return "info.circle"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.icon) }
                .tag(SettingsTab.general)

            ProfileSettingsView(profileStore: profileStore)
                .tabItem { Label(SettingsTab.profile.rawValue, systemImage: SettingsTab.profile.icon) }
                .tag(SettingsTab.profile)

            providersTab
                .tabItem { Label(SettingsTab.providers.rawValue, systemImage: SettingsTab.providers.icon) }
                .tag(SettingsTab.providers)
            
            chatTab
                .tabItem { Label(SettingsTab.chat.rawValue, systemImage: SettingsTab.chat.icon) }
                .tag(SettingsTab.chat)
            
            dataTab
                .tabItem { Label(SettingsTab.data.rawValue, systemImage: SettingsTab.data.icon) }
                .tag(SettingsTab.data)
            
            AgentSettingsView(dataStore: dataStore, aiManager: aiManager)
                .tabItem { Label(SettingsTab.agents.rawValue, systemImage: SettingsTab.agents.icon) }
                .tag(SettingsTab.agents)

            AutomationsSettingsView(scheduleService: scheduleService, dataStore: dataStore)
                .tabItem { Label(SettingsTab.automations.rawValue, systemImage: SettingsTab.automations.icon) }
                .tag(SettingsTab.automations)

            CustomToolSettingsView(dataStore: dataStore)
                .tabItem { Label(SettingsTab.customTools.rawValue, systemImage: SettingsTab.customTools.icon) }
                .tag(SettingsTab.customTools)
            
            if let mcpService {
                MCPSettingsView(mcpService: mcpService)
                    .tabItem { Label("MCP Servers", systemImage: "server.rack") }
                    .tag(SettingsTab.mcp)
            }
            
            aboutTab
                .tabItem { Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon) }
                .tag(SettingsTab.about)
        }
        .frame(width: 720, height: 580)
        .onAppear { consumeDeepLinkIfAny() }
    }

    /// Reads the one-shot deep-link tab key set by callers like the
    /// sidebar avatar's "Manage Profile" item, jumps the TabView there,
    /// and then clears the key so the next Settings open uses whichever
    /// tab the user last picked.
    private func consumeDeepLinkIfAny() {
        guard let raw = UserDefaults.standard.string(forKey: Self.deepLinkTabKey),
              let tab = SettingsTab(rawValue: raw) else { return }
        selectedTab = tab
        UserDefaults.standard.removeObject(forKey: Self.deepLinkTabKey)
    }
    
    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Toggle("Dark Mode", isOn: $isDarkMode)
            }
            
            Section("Window Behavior") {
                Toggle("Bubble Window Always on Top", isOn: $bubbleWindowAlwaysOnTop)
                    .onChange(of: bubbleWindowAlwaysOnTop) { _, _ in
                        BubbleWindowController.shared.updateWindowLevel()
                    }
            }
            
            Section("Voice") {
                Toggle("Auto-read AI Responses", isOn: $autoReadResponses)
            }
            
            Section("Hotkeys") {
                Toggle("Enable Global Shortcut", isOn: $enableGlobalShortcut)
                HotkeyRecorderRow()
                Text("Summons the LocalMind floating bubble from anywhere. Requires accessibility permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Providers Tab

    /// The model the active backend is answering with, if it exposes one.
    private var activeProviderModel: String? {
        switch aiManager.currentBackend {
        case .ollama: return aiManager.selectedOllamaModel
        case .openAICompatible: return aiManager.selectedOpenAIModel
        case .appleFoundationModels: return "On-device (Foundation Models)"
        case .none: return nil
        }
    }

    /// Where the active backend lives.
    private var activeProviderServer: String? {
        switch aiManager.currentBackend {
        case .ollama: return "http://localhost:11434"
        case .openAICompatible: return "\(aiManager.openAIServerName) — \(aiManager.openAIServerURL)"
        case .appleFoundationModels: return "This Mac"
        case .none: return nil
        }
    }

    private var availableModelCount: Int? {
        switch aiManager.currentBackend {
        case .ollama: return aiManager.availableModels.count
        case .openAICompatible: return aiManager.availableOpenAIModels.count
        case .appleFoundationModels, .none: return nil
        }
    }

    private func providerDetailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .textSelection(.enabled)
        }
    }

    private var providersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                // Current status — full details inline. (The sidebar's
                // StatusBadge is a bare dot with a hover popover, which reads
                // as broken in a settings pane.)
                GroupBox("Current Status") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        HStack {
                            Circle()
                                .fill(aiManager.currentBackend != .none
                                      ? AppTheme.Colors.statusOnline
                                      : AppTheme.Colors.statusOffline)
                                .frame(width: 9, height: 9)
                            Text(aiManager.statusMessage)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            if aiManager.isCheckingAvailability {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 8)
                            }
                            Button("Refresh") {
                                Task { await aiManager.refresh() }
                            }
                            .disabled(aiManager.isCheckingAvailability)
                        }

                        if aiManager.currentBackend != .none {
                            Divider()
                            Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.xl, verticalSpacing: 6) {
                                providerDetailRow("Backend", aiManager.currentBackend.rawValue)
                                if let model = activeProviderModel {
                                    providerDetailRow("Active model", model)
                                }
                                if let server = activeProviderServer {
                                    providerDetailRow("Server", server)
                                }
                                if let modelCount = availableModelCount {
                                    providerDetailRow("Models available", "\(modelCount)")
                                }
                                let toolCount = aiManager.getAvailableTools().count
                                if toolCount > 0 {
                                    providerDetailRow("MCP tools", "\(toolCount) connected")
                                }
                            }
                        }
                    }
                    .padding(AppTheme.Spacing.sm)
                }
                
                // Backend preference
                GroupBox("Preferred Backend") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        Picker("Backend:", selection: Binding(
                            get: { aiManager.preferredBackend ?? .appleFoundationModels },
                            set: { aiManager.preferredBackend = $0 }
                        )) {
                            Text("Apple Intelligence").tag(AIBackend.appleFoundationModels)
                            Text("Ollama").tag(AIBackend.ollama)
                            Text("OpenAI Compatible").tag(AIBackend.openAICompatible)
                        }
                        .pickerStyle(.segmented)
                        
                        Text("The app will try your preferred backend first, then auto-detect others if unavailable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(AppTheme.Spacing.sm)
                }
                
                // Ollama settings
                if aiManager.preferredBackend == .ollama || (aiManager.preferredBackend == nil && aiManager.currentBackend == .ollama) {
                    GroupBox("Ollama Settings") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                            if !aiManager.availableModels.isEmpty {
                                Picker("Model:", selection: Binding(
                                    get: { aiManager.selectedOllamaModel },
                                    set: { newValue in
                                        aiManager.selectedOllamaModel = newValue
                                        Task { await aiManager.refresh() }
                                    }
                                )) {
                                    ForEach(aiManager.availableModels) { model in
                                        Text("\(model.name) (\(model.formattedSize))")
                                            .tag(model.name)
                                    }
                                }
                            } else {
                                Picker("Model:", selection: .constant("Fetching...")) {
                                    Text(aiManager.isCheckingAvailability ? "Fetching models..." : "No models found.")
                                        .tag("Fetching...")
                                }
                                .disabled(true)
                            }
                        }
                        .padding(AppTheme.Spacing.sm)
                    }
                }
                
                // OpenAI-compatible server settings
                if aiManager.preferredBackend == .openAICompatible || (aiManager.preferredBackend == nil && aiManager.currentBackend == .openAICompatible) {
                    GroupBox("OpenAI-Compatible Server") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                            Picker("Server:", selection: Binding(
                                get: { aiManager.selectedPresetID },
                                set: { newValue in
                                    aiManager.selectedPresetID = newValue
                                    if let preset = LocalAIServerPreset.presets.first(where: { $0.id == newValue }) {
                                        aiManager.openAIServerURL = preset.defaultURL.absoluteString
                                    }
                                    Task { await aiManager.refresh() }
                                }
                            )) {
                                ForEach(LocalAIServerPreset.presets) { preset in
                                    Text(preset.name).tag(preset.id)
                                }
                            }
                            
                            HStack {
                                Text("URL:")
                                    .font(.caption)
                                TextField("http://localhost:1234", text: Binding(
                                    get: { aiManager.openAIServerURL },
                                    set: { aiManager.openAIServerURL = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                
                                Button("Connect") {
                                    Task { await aiManager.refresh() }
                                }
                                .controlSize(.small)
                            }
                            
                            if !aiManager.availableOpenAIModels.isEmpty {
                                Picker("Model:", selection: Binding(
                                    get: { aiManager.selectedOpenAIModel },
                                    set: { newValue in
                                        aiManager.selectedOpenAIModel = newValue
                                        Task { await aiManager.refresh() }
                                    }
                                )) {
                                    ForEach(aiManager.availableOpenAIModels) { model in
                                        Text(model.id).tag(model.id)
                                    }
                                }
                            } else {
                                Picker("Model:", selection: .constant("Fetching...")) {
                                    Text(aiManager.isCheckingAvailability ? "Fetching models..." : "No models found.")
                                        .tag("Fetching...")
                                }
                                .disabled(true)
                            }
                        }
                        .padding(AppTheme.Spacing.sm)
                    }
                }

                // In-app model management: pull/delete for Ollama, live
                // catalogue for OpenAI-compatible servers.
                GroupBox("Models") {
                    ModelManagerView(aiManager: aiManager)
                        .padding(AppTheme.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding(AppTheme.Spacing.xl)
        }
    }

    // MARK: - Chat Tab
    private var chatTab: some View {
        Form {
            Section(header: Text("Global Chat Rules"), footer: Text("These rules apply to all standard conversations.")) {
                TextEditor(text: $defaultSystemPrompt)
                    .frame(height: 100)
                    .font(.body)
            }
            
            Section(header: Text("Context Limit"), footer: Text("Number of past messages included to provide context (also capped by the model's token budget). When older messages fall out, a rolling summary keeps their gist in context.")) {
                Picker("Include past messages:", selection: $contextMessageLimit) {
                    Text("5 messages").tag(5)
                    Text("10 messages").tag(10)
                    Text("20 messages").tag(20)
                    Text("50 messages").tag(50)
                }
            }

            Section(header: Text("Memory"), footer: Text("Recalls relevant exchanges from your other conversations when you chat, so the AI remembers what you've discussed before. Indexed on-device with Apple embeddings; nothing leaves your Mac.")) {
                Toggle("Remember past conversations", isOn: $rememberPastChats)
                if rememberPastChats {
                    HStack {
                        Text("\(memoryEntryCount) exchange\(memoryEntryCount == 1 ? "" : "s") remembered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget everything") {
                            ChatMemoryStore.shared.forgetEverything()
                            memoryEntryCount = 0
                        }
                        .controlSize(.small)
                    }
                }
            }
            .onAppear { memoryEntryCount = ChatMemoryStore.shared.entryCount }
            .onChange(of: rememberPastChats) { _, enabled in
                // Backfill the index the moment the feature is switched on.
                guard enabled else { return }
                Task {
                    await ChatMemoryStore.shared.syncAll(dataStore.conversations)
                    memoryEntryCount = ChatMemoryStore.shared.entryCount
                }
            }
            
            Section(header: Text("Generation Parameters")) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack {
                        Text("Temperature: \(aiManager.aiParameters.temperature, specifier: "%.2f")")
                            .frame(width: 140, alignment: .leading)
                        Slider(value: Binding(
                            get: { aiManager.aiParameters.temperature },
                            set: { newValue in
                                var params = aiManager.aiParameters
                                params.temperature = newValue
                                aiManager.aiParameters = params
                            }
                        ), in: 0.0...2.0, step: 0.1)
                    }
                    Text("Higher values make output more random, lower values make it more focused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack {
                        Text("Top-P: \(aiManager.aiParameters.topP ?? 1.0, specifier: "%.2f")")
                            .frame(width: 140, alignment: .leading)
                        Slider(value: Binding(
                            get: { aiManager.aiParameters.topP ?? 1.0 },
                            set: { newValue in
                                var params = aiManager.aiParameters
                                params.topP = newValue
                                aiManager.aiParameters = params
                            }
                        ), in: 0.0...1.0, step: 0.05)
                    }
                    Text("Limits tokens to top cumulative probability. 1.0 means no limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Data Tab
    private var dataTab: some View {
        Form {
            Section("Export") {
                Button("Export All Conversations") {
                    exportAllData()
                }
                Text("Exports all your chat history as a single JSON file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Import") {
                Button("Import Conversations…") {
                    importConversations()
                }
                if !importStatus.isEmpty {
                    Text(importStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Adds conversations from a previously-exported JSON file. Existing conversations are kept; updates merge by most recent timestamp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Danger Zone") {
                Button("Clear All Chat History") {
                    confirmingClearHistory = true
                }
                .foregroundStyle(AppTheme.Colors.statusOffline)
                Text("This action cannot be undone. It will delete all stored messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete all \(dataStore.totalConversationCount) conversations?",
            isPresented: $confirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                dataStore.deleteAllConversations()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every conversation across all profiles will be permanently deleted. Consider exporting first.")
        }
    }
    
    private func importConversations() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "json") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            let count = dataStore.importConversations(from: data)
            importStatus = count == 0
                ? "Could not parse the file — is it a LocalMind export?"
                : "Imported \(count) conversation\(count == 1 ? "" : "s")."
        }
    }

    private func exportAllData() {
        if let data = try? JSONEncoder().encode(dataStore.conversations) {
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType(filenameExtension: "json") ?? .data]
            savePanel.nameFieldStringValue = "LocalMind_Export.json"
            
            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    try? data.write(to: url)
                }
            }
        }
    }
    
    // MARK: - About Tab
    private var aboutTab: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(AppTheme.Colors.accentGradient)
            VStack(spacing: AppTheme.Spacing.sm) {
                Text("LocalMind")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                Text("Version 1.0")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Your private, local AI productivity assistant.\nAll processing happens on your Mac — nothing leaves your device.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }
            Spacer()
        }
        .padding(AppTheme.Spacing.xl)
    }
}

struct HotkeyRecorderRow: View {
    @State private var isRecording = false
    @State private var currentDescription: String = HotkeyManager.shared.currentShortcutDescription()

    var body: some View {
        HStack {
            Text("Global Shortcut")
            Spacer()
            if isRecording {
                ShortcutRecorder { keyCode, modifiers in
                    HotkeyManager.shared.updateHotkey(keyCode: keyCode, modifiers: modifiers)
                    currentDescription = HotkeyManager.shared.currentShortcutDescription()
                    isRecording = false
                }
                .frame(width: 140, height: 22)
            } else {
                Button(currentDescription) { isRecording = true }
                    .buttonStyle(.bordered)
            }
            Button("Reset") {
                HotkeyManager.shared.resetHotkey()
                currentDescription = HotkeyManager.shared.currentShortcutDescription()
                isRecording = false
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderHost {
        let host = ShortcutRecorderHost()
        host.onCapture = onCapture
        return host
    }

    func updateNSView(_ nsView: ShortcutRecorderHost, context: Context) {
        nsView.onCapture = onCapture
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView.recorder)
        }
    }
}

final class ShortcutRecorderHost: NSView {
    let recorder = ShortcutRecorderView()
    var onCapture: ((UInt32, UInt32) -> Void)? {
        didSet { recorder.onCapture = onCapture }
    }

    init() {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "Press a shortcut…")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        recorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recorder)
        recorder.addSubview(label)
        recorder.wantsLayer = true
        recorder.layer?.borderColor = NSColor.controlAccentColor.cgColor
        recorder.layer?.borderWidth = 1
        recorder.layer?.cornerRadius = 4
        NSLayoutConstraint.activate([
            recorder.topAnchor.constraint(equalTo: topAnchor),
            recorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            recorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            recorder.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        label.centerXAnchor.constraint(equalTo: recorder.centerXAnchor).isActive = true
        label.centerYAnchor.constraint(equalTo: recorder.centerYAnchor).isActive = true
    }

    required init?(coder: NSCoder) { nil }
}
