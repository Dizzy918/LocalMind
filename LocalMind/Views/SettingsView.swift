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
    
    @State private var selectedTab: SettingsTab = .general
    
    // New AppStorage bindings
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @AppStorage("bubbleWindowAlwaysOnTop") private var bubbleWindowAlwaysOnTop: Bool = false
    @AppStorage("autoReadResponses") private var autoReadResponses: Bool = false
    @AppStorage("enableGlobalShortcut") private var enableGlobalShortcut: Bool = false
    @AppStorage("defaultSystemPrompt") private var defaultSystemPrompt: String = "You are LocalMind, a helpful, concise AI assistant. Provide clear, actionable responses. Use markdown formatting when appropriate."
    @AppStorage("contextMessageLimit") private var contextMessageLimit: Int = 10
    
    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case providers = "Providers"
        case chat = "Chat Options"
        case data = "Data & Privacy"
        case customTools = "Custom Tools"
        case about = "About"
        
        var icon: String {
            switch self {
            case .general: return "gear"
            case .providers: return "network"
            case .chat: return "message"
            case .data: return "lock.shield"
            case .customTools: return "hammer"
            case .about: return "info.circle"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.icon) }
                .tag(SettingsTab.general)
                
            providersTab
                .tabItem { Label(SettingsTab.providers.rawValue, systemImage: SettingsTab.providers.icon) }
                .tag(SettingsTab.providers)
                
            chatTab
                .tabItem { Label(SettingsTab.chat.rawValue, systemImage: SettingsTab.chat.icon) }
                .tag(SettingsTab.chat)
                
            dataTab
                .tabItem { Label(SettingsTab.data.rawValue, systemImage: SettingsTab.data.icon) }
                .tag(SettingsTab.data)
                
            CustomToolSettingsView(dataStore: dataStore)
                .tabItem { Label(SettingsTab.customTools.rawValue, systemImage: SettingsTab.customTools.icon) }
                .tag(SettingsTab.customTools)
            
            aboutTab
                .tabItem { Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon) }
                .tag(SettingsTab.about)
        }
        .frame(width: 550, height: 550)
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
                Toggle("Enable Global Shortcut (Option + Space)", isOn: $enableGlobalShortcut)
                Text("Summons the LocalMind floating bubble from anywhere. Note: Currently this shortcut requires accessibility permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Providers Tab
    private var providersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                // Current status
                GroupBox("Current Status") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        HStack {
                            StatusBadge(
                                backend: aiManager.currentBackend,
                                statusMessage: aiManager.statusMessage
                            )
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
            
            Section(header: Text("Context Limit"), footer: Text("Number of past messages included to provide context. Higher uses more memory.")) {
                Picker("Include past messages:", selection: $contextMessageLimit) {
                    Text("5 messages").tag(5)
                    Text("10 messages").tag(10)
                    Text("20 messages").tag(20)
                    Text("50 messages").tag(50)
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
            
            Section("Danger Zone") {
                Button("Clear All Chat History") {
                    dataStore.deleteAllConversations()
                }
                .foregroundStyle(AppTheme.Colors.statusOffline)
                Text("This action cannot be undone. It will delete all stored messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
