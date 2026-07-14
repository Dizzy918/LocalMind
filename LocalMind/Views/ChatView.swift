//
//  ChatView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import PDFKit
import WebKit
#endif

/// Full chat interface with streaming AI responses
struct ChatView: View {
    let aiManager: AIServiceManager
    let dataStore: DataStore
    let generationService: ChatGenerationService
    @Binding var conversation: Conversation

    @State private var inputText = ""
    @State private var scrollProxy: ScrollViewProxy?

    /// Streaming state lives in the generation service (keyed by conversation
    /// ID) so an in-flight answer survives switching conversations.
    private var isStreaming: Bool {
        generationService.isStreaming(conversation.id)
    }

    private var streamingContent: String {
        generationService.streamingText(conversation.id)
    }
    
    // Vision / Drop states
    @State private var attachedImageData: Data?
    @State private var isTargetedByDrop = false
    @State private var isProcessingImage = false
    
    // Prompt History state (0 means current empty input, 1 means last sent message, etc.)
    @State private var historyOffset: Int = 0
    
    // Voice Dictation
    @State private var voiceManager = VoiceManager()
    @State private var preDictationText = "" // Saves text that existed before hitting record

    // Draft Recovery
    @State private var draftSaveTask: Task<Void, Never>?

    // System prompt editor
    @State private var showingSystemPromptEditor = false

    // Per-conversation model & generation parameters
    @State private var showingModelSettings = false
    // Live slider value, committed to the conversation only on release so a
    // drag doesn't trigger a disk write on every tick.
    @State private var tempDraft: Double = AIParameters.default.temperature

    // Side-by-side "compare with another model" sheet
    @State private var comparison: ModelComparisonRequest?

    // Conversation branches (versions saved on edit/regenerate)
    @State private var showingBranches = false

    // Knowledge base ("chat with your documents")
    @State private var showingKnowledgeBase = false
    @AppStorage("useKnowledgeBase") private var useKnowledgeBase = false

    // Agent Team — run several agents against one prompt in parallel
    @State private var showingAgentTeam = false

    @Environment(\.openSettings) private var openSettingsAction

    // One-time onboarding hint shown on the empty welcome screen.
    @AppStorage("hasSeenWelcomeHint") private var hasSeenWelcomeHint = false

    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        ZStack {
            // Invisible background buttons for Up / Down prompt history
            Button("") { navigateHistory(up: true) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0)
            
            Button("") { navigateHistory(up: false) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0)
            
            // Invisible background button to catch Cmd+V for Images
            Button("") { pasteImageFromClipboard() }
                .keyboardShortcut("v", modifiers: .command)
                .opacity(0)
            
            VStack(spacing: 0) {
                if conversation.messages.isEmpty && !isStreaming {
                    // Centered welcome layout — input in the middle like ChatGPT/Claude
                    welcomeLayout
                } else {
                    chatHeader
                    Divider().overlay(AppTheme.Colors.divider)
                    messagesArea
                    inputBar
                }
            }
            .background(AppTheme.Colors.backgroundPrimary)
            // Global drop zone for the entire chat view
            .onDrop(of: [.image, .pdf, .plainText], isTargeted: $isTargetedByDrop) { providers in
                if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
                    isProcessingImage = true // Show loading indicator
                    
                    provider.loadObject(ofClass: NSImage.self) { image, error in
                        if let nsImage = image as? NSImage {
                            // Explicitly hop back to the MainActor
                            Task { @MainActor in
                                let optimizedData = optimizeImageForAI(nsImage)
                                self.attachedImageData = optimizedData
                                self.isProcessingImage = false
                            }
                        } else {
                            Task { @MainActor in
                                self.isProcessingImage = false
                            }
                        }
                    }
                    return true
                } else if let provider = providers.first {
                    // Try to load as a file URL for PDF/Text
                    provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { (item, error) in
                        guard let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        
                        Task { @MainActor in
                            do {
                                let fileExtension = url.pathExtension.lowercased()
                                var extractedText = ""
                                
                                if fileExtension == "pdf" {
                                    if let pdfDocument = PDFDocument(url: url) {
                                        extractedText = (0..<pdfDocument.pageCount).compactMap { pdfDocument.page(at: $0)?.string }.joined(separator: "\n")
                                    }
                                } else {
                                    extractedText = try String(contentsOf: url, encoding: .utf8)
                                }
                                
                                if !extractedText.isEmpty {
                                    if !self.inputText.isEmpty { self.inputText += "\n\n" }
                                    self.inputText += "📄 \(url.lastPathComponent):\n```\n\(extractedText)\n```\n"
                                }
                            } catch {
                                print("Failed to read dropped file: \(error)")
                            }
                        }
                    }
                    return true
                }
                return false
            }
            .overlay {
                if isTargetedByDrop {
                    ZStack {
                        Color.black.opacity(0.8)
                        VStack(spacing: AppTheme.Spacing.md) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 64))
                                .foregroundStyle(AppTheme.Colors.accentPrimary)
                            Text("Drop image or document to analyze")
                                .font(AppTheme.Typography.title)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .onAppear {
            restoreDraft()
            generationService.markSeen(conversation.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isInputFocused = true
            }
        }
        .onChange(of: conversation.messages.count) { oldCount, newCount in
            // A background generation just delivered into the visible chat.
            generationService.markSeen(conversation.id)
            if newCount > oldCount,
               let last = conversation.messages.last, last.role == .assistant,
               UserDefaults.standard.bool(forKey: "autoReadResponses") {
                voiceManager.speak(text: last.content)
            }
        }
        .onChange(of: inputText) { _, newValue in
            // Capture the conversation id NOW, not inside the task. If the
            // user switches chats within the 2s debounce window, the binding
            // will resolve to a different conversation by the time the task
            // fires — and we'd overwrite the wrong draft key.
            let conversationID = conversation.id
            draftSaveTask?.cancel()
            draftSaveTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(newValue, forKey: "draft_\(conversationID.uuidString)")
            }
        }
        .sheet(item: $comparison) { request in
            ModelCompareView(
                request: request,
                aiManager: aiManager,
                candidateModels: aiManager.allAvailableModelIDs,
                onReplace: { newText in
                    if let idx = conversation.messages.firstIndex(where: { $0.id == request.messageID }) {
                        conversation.messages[idx].content = newText
                        conversation.updatedAt = Date()
                    }
                    comparison = nil
                },
                onClose: { comparison = nil }
            )
        }
        // Tool-call approval gate. The MCP service publishes a pending request
        // while a generation is blocked waiting on the user's decision.
        .alert(
            "Allow tool call?",
            isPresented: Binding(
                get: { aiManager.mcpService?.pendingApproval != nil },
                // Dismissal is driven by the buttons (which clear the pending
                // request); a no-op setter avoids resolving the continuation twice.
                set: { _ in }
            ),
            presenting: aiManager.mcpService?.pendingApproval
        ) { request in
            Button("Allow once") { request.respond(.allowOnce) }
            Button("Always allow this tool") { request.respond(.allowAlways) }
            Button("Deny", role: .cancel) { request.respond(.deny) }
        } message: { request in
            Text("\(request.serverName) wants to run “\(request.toolName)”.\n\n\(request.argumentsPreview)")
        }
        .sheet(isPresented: $showingKnowledgeBase) {
            KnowledgeBaseView(store: KnowledgeBaseStore.shared) {
                showingKnowledgeBase = false
            }
        }
        .sheet(isPresented: $showingAgentTeam) {
            AgentTeamView(
                aiManager: aiManager,
                dataStore: dataStore,
                onClose: { showingAgentTeam = false }
            )
        }
    }

    // MARK: - Agents

    /// The agent persona assigned to this conversation, if any.
    private var currentAgent: Agent? {
        dataStore.agent(withID: conversation.agentID)
    }

    /// Menu for assigning an agent to this conversation, launching the Agent
    /// Team panel, or jumping to agent management in Settings.
    private var agentPicker: some View {
        Menu {
            if dataStore.agents.count >= 2 {
                Toggle(isOn: Binding(
                    get: { conversation.autoRouteAgent },
                    set: { enabled in
                        conversation.autoRouteAgent = enabled
                        conversation.updatedAt = Date()
                    }
                )) {
                    Label("Auto — route each message to the best agent", systemImage: "sparkles")
                }
                Divider()
            }

            Picker("Agent", selection: Binding(
                get: { conversation.agentID },
                set: { newValue in
                    conversation.agentID = newValue
                    conversation.updatedAt = Date()
                }
            )) {
                Text("Default assistant").tag(UUID?.none)
                ForEach(dataStore.agents) { agent in
                    Text("\(agent.emoji) \(agent.name)").tag(Optional(agent.id))
                }
            }
            .pickerStyle(.inline)
            .disabled(conversation.autoRouteAgent)

            Divider()

            Button {
                showingAgentTeam = true
            } label: {
                Label("Ask multiple agents…", systemImage: "person.3")
            }

            Button {
                UserDefaults.standard.set(SettingsView.SettingsTab.agents.rawValue,
                                          forKey: SettingsView.deepLinkTabKey)
                openSettingsAction()
                #if os(macOS)
                NSApp.activate()
                #endif
            } label: {
                Label("Manage agents…", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 4) {
                if conversation.autoRouteAgent {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.accentPrimary)
                    Text("Auto")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.accentPrimary)
                } else if let agent = currentAgent {
                    Text(agent.emoji)
                        .font(.system(size: 12))
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.accentPrimary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "person.crop.circle.dashed")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(conversation.autoRouteAgent
              ? "Each message is routed to the best-fitting agent"
              : (currentAgent.map { "\($0.name) is answering this conversation — \(aiManager.resolvedModelDescription(for: $0))" }
                 ?? "Assign an agent to this conversation"))
    }

    // MARK: - Chat Header

    private var chatHeader: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(conversation.title)
                .font(AppTheme.Typography.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(1)

            if !conversation.messages.isEmpty {
                Text(tokenCountLabel)
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, 2)
                    .background {
                        Capsule()
                            .fill(AppTheme.Colors.backgroundTertiary.opacity(0.6))
                    }
                    .help("Approximate token count for this conversation")
            }

            Spacer()

            // Branch navigator — only appears once the chat has forked at least
            // once (an edit or regenerate saved a previous version).
            if !conversation.branches.isEmpty {
                Button {
                    showingBranches = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 13))
                        Text("\(conversation.branches.count)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Earlier versions of this conversation")
                .popover(isPresented: $showingBranches, arrowEdge: .bottom) {
                    branchListPopover
                }
            }

            // Agent persona for this conversation.
            agentPicker

            // Knowledge base — "chat with your documents". Filled when active.
            Button {
                showingKnowledgeBase = true
            } label: {
                Image(systemName: useKnowledgeBase ? "books.vertical.fill" : "books.vertical")
                    .font(.system(size: 14))
                    .foregroundStyle(useKnowledgeBase ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help(useKnowledgeBase ? "Your documents are being used in chats" : "Chat with your documents")

            // Per-conversation model & generation parameters. "cpu" reads as
            // "which model / how it generates" for this chat specifically.
            Button {
                showingModelSettings = true
            } label: {
                Image(systemName: "cpu")
                    .font(.system(size: 14))
                    .foregroundStyle(hasModelParamOverride ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textTertiary)
                    .symbolVariant(hasModelParamOverride ? .fill : .none)
            }
            .buttonStyle(.plain)
            .help(hasModelParamOverride ? "Custom model / temperature set for this conversation" : "Set model & temperature for this conversation")
            .popover(isPresented: $showingModelSettings, arrowEdge: .bottom) {
                modelSettingsPopover
            }

            // Per-conversation system-prompt override (left of export). Uses a
            // "tuning sliders" glyph so it reads as conversation behaviour /
            // custom instructions rather than a profile/account control.
            Button {
                showingSystemPromptEditor = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(conversation.systemPromptOverride != nil ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textTertiary)
                    .symbolVariant(conversation.systemPromptOverride != nil ? .fill : .none)
            }
            .buttonStyle(.plain)
            .help(conversation.systemPromptOverride != nil ? "Custom instructions set for this conversation" : "Set custom instructions for this conversation")

            // Export menu — kept furthest right.
            Menu {
                Button {
                    exportChat(as: .markdown)
                } label: {
                    Label("Markdown (.md)", systemImage: "doc.text")
                }
                Button {
                    exportChat(as: .json)
                } label: {
                    Label("JSON (.json)", systemImage: "curlybraces")
                }
                Button {
                    exportChat(as: .plainText)
                } label: {
                    Label("Plain Text (.txt)", systemImage: "doc.plaintext")
                }
                Button {
                    exportChat(as: .html)
                } label: {
                    Label("HTML (.html)", systemImage: "globe")
                }
                Button {
                    exportChat(as: .pdf)
                } label: {
                    Label("PDF (.pdf)", systemImage: "doc.richtext")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(conversation.messages.isEmpty)
            .help("Export conversation")
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.sm)
        .sheet(isPresented: $showingSystemPromptEditor) {
            SystemPromptEditor(
                initial: conversation.systemPromptOverride ?? "",
                onSave: { newValue in
                    conversation.systemPromptOverride = newValue.isEmpty ? nil : newValue
                    showingSystemPromptEditor = false
                },
                onCancel: { showingSystemPromptEditor = false }
            )
        }
    }

    /// Hybrid token estimate: word count × 1.33 for natural language,
    /// plus char/4 for non-word characters (punctuation, code symbols).
    /// Matches GPT-style BPE counts within ~10% for both prose and code.
    private var tokenCountLabel: String {
        // Strip hidden <think> blocks (present in messages saved by older
        // builds) so the count reflects what the user actually sees.
        let full = conversation.messages.map(\.content).joined(separator: " ").strippingThinkBlocks
        let tokens = TokenEstimator.estimate(full)
        if tokens >= 1000 {
            return "\(String(format: "%.1f", Double(tokens) / 1000))k tokens"
        }
        return "\(tokens) tokens"
    }

    // MARK: - Per-conversation model & parameters

    /// True when this conversation pins its own model or temperature.
    private var hasModelParamOverride: Bool {
        conversation.modelOverride != nil || conversation.temperatureOverride != nil
    }

    /// Label for the backend's globally-selected model — shown as the
    /// "Default" option so the user knows what they fall back to.
    private var globalModelLabel: String {
        switch aiManager.currentBackend {
        case .ollama: return aiManager.selectedOllamaModel
        case .openAICompatible: return aiManager.selectedOpenAIModel
        case .appleFoundationModels: return "Apple Intelligence"
        case .none: return "—"
        }
    }

    /// Pins a model and/or temperature for this conversation only. Both follow
    /// the global settings until explicitly overridden; "Reset" clears them.
    /// Mutating `conversation` persists automatically via its binding setter.
    private var modelSettingsPopover: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model & Parameters")
                    .font(AppTheme.Typography.headline)
                Text("Applies to this conversation only.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
            }

            if !aiManager.allAvailableModelIDs.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("MODEL")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .tracking(1.2)
                    Picker("", selection: Binding(
                        get: { conversation.modelOverride ?? "" },
                        set: { conversation.modelOverride = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Default (\(globalModelLabel))").tag("")
                        ForEach(aiManager.allAvailableModelIDs, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            } else {
                Text("The active backend (\(globalModelLabel)) doesn't expose selectable models.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack {
                    Text("TEMPERATURE")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .tracking(1.2)
                    Spacer()
                    Text(String(format: "%.2f", tempDraft))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(conversation.temperatureOverride != nil ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textSecondary)
                }
                Slider(value: $tempDraft, in: 0...1, step: 0.05) { editing in
                    if !editing { conversation.temperatureOverride = tempDraft }
                }
                Text("Lower = focused & deterministic · Higher = creative & varied")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }

            Divider()

            HStack {
                Button("Reset to defaults") {
                    conversation.modelOverride = nil
                    conversation.temperatureOverride = nil
                    tempDraft = aiManager.aiParameters.temperature
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!hasModelParamOverride)
                Spacer()
                Button("Done") { showingModelSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 320)
        .onAppear { tempDraft = conversation.temperatureOverride ?? aiManager.aiParameters.temperature }
    }

    // MARK: - Branch navigator

    private var branchListPopover: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversation Branches")
                    .font(AppTheme.Typography.headline)
                Text("Versions saved when you edited or regenerated. Restore one to bring that path back.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(conversation.branches.reversed()) { branch in
                        branchRow(branch)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 380, height: 380)
    }

    private func branchRow(_ branch: ConversationBranch) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(branch.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("\(branch.messages.count) messages" + (branch.messages.last.map { " · \($0.content.prefix(48))" } ?? ""))
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Restore") { restoreBranch(branch) }
                .controlSize(.small)
            Button {
                deleteBranch(branch)
            } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete this saved version")
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppTheme.Colors.backgroundSecondary.opacity(0.5))
        )
    }

    // MARK: - Messages Area

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.xl) {
                    ForEach(conversation.messages) { message in
                        MessageBubble(
                            message: message,
                            isStreaming: false,
                            onPlay: { voiceManager.speak(text: message.content) },
                            onDelete: { deleteMessage(message) },
                            onEdit: message.role == .user ? { newContent in editAndResend(message: message, newContent: newContent) } : nil,
                            onRegenerate: message.role == .assistant ? { regenerate(from: message) } : nil,
                            onCompare: message.role == .assistant ? { startComparison(for: message) } : nil,
                            onSelectVariant: message.role == .assistant ? { index in selectVariant(for: message, index: index) } : nil
                        )
                        .id(message.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if isStreaming && !streamingContent.isEmpty {
                        MessageBubble(
                            message: streamingPreviewMessage,
                            isStreaming: true,
                            onPlay: { voiceManager.speak(text: streamingContent) }
                        )
                        .id("streaming")
                    } else if isStreaming {
                        HStack(spacing: AppTheme.Spacing.md) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.accentPrimary)
                                .frame(width: 28, height: 28)
                                .background {
                                    Circle()
                                        .fill(AppTheme.Colors.accentPrimary.opacity(0.12))
                                }
                            TypingIndicator()
                            Spacer()
                        }
                        .id("typing")
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.vertical, AppTheme.Spacing.lg)
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: conversation.messages.count) { _, _ in scrollToBottom(proxy: proxy) }
            .onChange(of: streamingContent) { _, _ in scrollToBottom(proxy: proxy) }
        }
    }

    /// The in-progress answer as a message, carrying the answering agent's
    /// attribution so the streaming bubble is labeled like the final one.
    /// Reasoning is split out live, so while the model is still inside a
    /// <think> block the bubble shows a "Thinking…" disclosure, not raw tags.
    private var streamingPreviewMessage: ChatMessage {
        let (reasoning, answer) = streamingContent.separatingThinkBlocks
        var message = ChatMessage(role: .assistant, content: answer)
        message.reasoning = reasoning
        let attribution = generationService.liveAttribution(conversation.id)
        message.agentName = attribution.name
        message.agentEmoji = attribution.emoji
        return message
    }
    
    // MARK: - Welcome Layout (centered input like ChatGPT/Claude)

    private var welcomeLayout: some View {
        VStack(spacing: 0) {
            if !hasSeenWelcomeHint {
                welcomeHint
            }

            Spacer()

            VStack(spacing: AppTheme.Spacing.xxl) {
                VStack(spacing: AppTheme.Spacing.lg) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(AppTheme.Colors.accentGradient)

                    Text("What can I help you with?")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }

                inputBar

                // Agent controls for a brand-new chat (the header, which
                // normally hosts these, only appears once messages exist).
                HStack(spacing: AppTheme.Spacing.md) {
                    agentPicker
                    if !dataStore.agents.isEmpty {
                        Button {
                            showingAgentTeam = true
                        } label: {
                            Label("Ask multiple agents", systemImage: "person.3")
                                .font(AppTheme.Typography.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .help("Send one prompt to several agents in parallel")
                    }
                }
            }

            Spacer()

            // Suggestion chips at the bottom
            VStack(spacing: AppTheme.Spacing.md) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppTheme.Spacing.sm) {
                    SuggestionChip(icon: "pencil.and.outline", text: "Help me write an email", color: .blue) {
                        inputText = "Help me write a professional email about "
                    }
                    SuggestionChip(icon: "lightbulb", text: "Brainstorm ideas", color: .orange) {
                        inputText = "Help me brainstorm ideas for "
                    }
                    SuggestionChip(icon: "doc.text.magnifyingglass", text: "Summarize a document", color: .purple) {
                        inputText = "Can you summarize this for me: "
                    }
                    SuggestionChip(icon: "chevron.left.forwardslash.chevron.right", text: "Help me code", color: .green) {
                        inputText = "Help me write code that "
                    }
                }
                .frame(maxWidth: 600)

                Text("Drop or paste (Cmd+V) an image to analyze it")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }
            .padding(.bottom, AppTheme.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    /// One-time onboarding banner — dismisses for good once seen. Points the
    /// user at the ? button rather than forcing a modal tour.
    private var welcomeHint: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "hand.wave")
                .foregroundStyle(AppTheme.Colors.accentPrimary)

            Text("Welcome! Press ⌘N for a new chat, drop a file to analyze it, or click ? in the sidebar for shortcuts.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: AppTheme.Spacing.md)

            Button {
                withAnimation(AppTheme.Animations.quick) { hasSeenWelcomeHint = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                .fill(AppTheme.Colors.accentPrimary.opacity(0.08))
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.top, AppTheme.Spacing.lg)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Attachment preview inside the pill
                if isProcessingImage {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Optimizing image...")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.md)
                } else if let data = attachedImageData, let nsImage = NSImage(data: data) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Image attached")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.textPrimary)

                            if !aiManager.selectedOllamaModel.lowercased().contains("llava") {
                                Text("Requires llava model for vision")
                                    .font(AppTheme.Typography.captionSecondary)
                                    .foregroundStyle(AppTheme.Colors.accentOrange)
                            }
                        }

                        Spacer()

                        Button {
                            attachedImageData = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.md)
                }

                // Text field row
                HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                    // Left action buttons
                    HStack(spacing: 2) {
                        HoverIconButton(
                            systemName: "paperclip",
                            size: 16,
                            helpText: "Attach file",
                            action: pickFile
                        )

                        HStack(spacing: 2) {
                            HoverIconButton(
                                systemName: voiceManager.isRecording ? "mic.fill" : "mic",
                                size: 16,
                                baseColor: voiceManager.isRecording ? .red : AppTheme.Colors.textTertiary,
                                hoverColor: voiceManager.isRecording ? .red : AppTheme.Colors.textPrimary,
                                helpText: voiceManager.isRecording ? "Stop" : "Dictate",
                                action: { voiceManager.toggleRecording() }
                            )

                            if voiceManager.isRecording {
                                AudioLevelIndicator(level: voiceManager.audioLevel)
                                    .transition(.opacity)
                            }
                        }
                        .animation(AppTheme.Animations.quick, value: voiceManager.isRecording)
                    }

                    // Text input
                    ZStack(alignment: .topLeading) {
                        if voiceManager.isRecording {
                            let prefix = preDictationText.trimmingCharacters(in: .whitespaces)
                            let space = prefix.isEmpty || voiceManager.transcribedText.isEmpty ? "" : " "
                            Text(dictationAttributedString(prefix: prefix, space: space, dictated: voiceManager.transcribedText))
                                .font(AppTheme.Typography.body)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        TextField("Message LocalMind...", text: $inputText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(AppTheme.Typography.body)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1...8)
                            .opacity(voiceManager.isRecording ? 0 : 1)
                            .focused($isInputFocused)
                    }
                    .onChange(of: voiceManager.isRecording) { _, isRecording in
                        if isRecording { preDictationText = inputText }
                    }
                    .onChange(of: voiceManager.transcribedText) { _, newText in
                        if voiceManager.isRecording {
                            let prefix = preDictationText.trimmingCharacters(in: .whitespaces)
                            inputText = prefix.isEmpty ? newText : (newText.isEmpty ? prefix : prefix + " " + newText)
                        }
                    }
                    .onSubmit {
                        if canSend { sendMessage() }
                    }

                    // Send button — icon must contrast with accentPrimary which
                    // is white in dark mode and black in light mode.
                    Button {
                        if isStreaming { stopStreaming() } else { sendMessage() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(canSend || isStreaming ? AppTheme.Colors.accentPrimary : AppTheme.Colors.backgroundTertiary)
                            Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(
                                    canSend || isStreaming
                                        ? AppTheme.Colors.backgroundPrimary
                                        : AppTheme.Colors.textTertiary
                                )
                        }
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .disabled(!canSend && !isStreaming)
                    .keyboardShortcut(.return, modifiers: .command)
                    .symbolEffect(.bounce, value: isStreaming)
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
            }
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusXL)
                    .fill(AppTheme.Colors.backgroundSecondary)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusXL)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.Colors.backgroundPrimary)
    }
    
    // MARK: - Actions
    
    private var isVisionCompatible: Bool {
        if aiManager.currentBackend == .ollama {
            return aiManager.selectedOllamaModel.lowercased().contains("llava")
        }
        return true
    }
    
    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = attachedImageData != nil
        
        if hasImage && !isVisionCompatible {
            return false
        }
        
        return (hasText || hasImage)
        && !isStreaming
        && aiManager.currentService != nil
    }
    
    private func sendMessage() {
        guard canSend else { return }
        
        // Stop dictation gracefully if user sends while still speaking
        if voiceManager.isRecording {
            voiceManager.stopRecording()
        }
        
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalContent = (content.isEmpty && attachedImageData != nil) ? "Please describe this image." : content
        
        let userMessage = ChatMessage(role: .user, content: finalContent, imageData: attachedImageData)
        conversation.messages.append(userMessage)
        conversation.updateTitleIfNeeded()
        conversation.updatedAt = Date()
        
        inputText = ""
        attachedImageData = nil
        historyOffset = 0
        clearDraft()
        
        dataStore.saveConversation(conversation)
        
        // Trigger a background task to guess the icon and title if this is the first message
        if conversation.messages.filter({ $0.role == .user }).count == 1 {
            generateEmojiIfNeeded()
            generateTitleIfNeeded()
        }

        generationService.start(conversationID: conversation.id)
    }
    
    /// Asks the AI to generate a title for the conversation
    private func generateTitleIfNeeded() {
        guard let firstMessage = conversation.messages.first(where: { $0.role == .user }),
              let service = aiManager.currentService else { return }
        
        Task { @MainActor in
            let truncated = String(firstMessage.content.prefix(300))
            let prompt = """
            Generate a short, specific title (3-6 words) for a conversation that starts with this message:

            "\(truncated)"

            Rules:
            - Be specific to the topic, not generic (e.g. "Python Sorting Algorithm Help" not "Coding Question")
            - Use title case
            - No quotes, no punctuation at the end, no preamble
            - If the message asks about a specific thing, name that thing
            - Reply with ONLY the title
            """

            do {
                let response = try await service.generateOnce(
                    prompt: prompt,
                    systemPrompt: "You are a concise title generator. Output only the title, nothing else. No quotes, no explanation.",
                    modelOverride: nil,
                    parameters: aiManager.aiParameters,
                    tools: nil
                )

                var title = response
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .components(separatedBy: .newlines).first ?? ""

                // Strip common preamble patterns the model might add
                for prefix in ["Title: ", "title: ", "Title - "] {
                    if title.hasPrefix(prefix) {
                        title = String(title.dropFirst(prefix.count))
                    }
                }

                if title.isEmpty || title.count > 60 {
                    title = String(firstMessage.content.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.count == 40 { title += "..." }
                }

                conversation.title = title
                dataStore.saveConversation(conversation)
            } catch {
                var fallback = String(firstMessage.content.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
                if fallback.count == 40 { fallback += "..." }
                conversation.title = fallback
                dataStore.saveConversation(conversation)
            }
        }
    }
    
    /// Asks the AI to pick a relevant emoji for the conversation topic
    private func generateEmojiIfNeeded() {
        guard conversation.emoji == nil,
              let firstMessage = conversation.messages.first(where: { $0.role == .user }),
              let service = aiManager.currentService else { return }
        
        Task { @MainActor in
            let prompt = """
            Pick ONE emoji that best represents this topic: "\(firstMessage.content)"
            Reply with EXACTLY one emoji character. Nothing else.
            """
            
            do {
                let response = try await service.generateOnce(
                    prompt: prompt,
                    systemPrompt: "You output exactly one emoji. No words, no punctuation, just one emoji.",
                    modelOverride: nil,
                    parameters: aiManager.aiParameters,
                    tools: nil
                )
                
                // Extract the first emoji from the response
                let emoji = extractFirstEmoji(from: response)
                
                if let emoji {
                    conversation.emoji = String(emoji)
                    dataStore.saveConversation(conversation)
                } else {
                    conversation.emoji = conversation.toolType.emoji
                    dataStore.saveConversation(conversation)
                }
            } catch {
                conversation.emoji = conversation.toolType.emoji
                dataStore.saveConversation(conversation)
            }
        }
    }
    
    /// Scans a string and returns the first emoji character found
    private func extractFirstEmoji(from string: String) -> Character? {
        for char in string {
            if char.unicodeScalars.first?.properties.isEmoji == true && char.unicodeScalars.first?.value ?? 0 > 0x23F {
                return char
            }
        }
        return nil
    }
    
    // MARK: - Message Actions

    /// Delete a single message from the conversation.
    private func deleteMessage(_ message: ChatMessage) {
        conversation.messages.removeAll { $0.id == message.id }
        conversation.updatedAt = Date()
        dataStore.saveConversation(conversation)
    }

    /// Replace a user message's content and regenerate the AI response from that point.
    /// Drops everything after the edited message, then asks the AI to respond again.
    private func editAndResend(message: ChatMessage, newContent: String) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }

        // Stop any in-flight stream first
        if isStreaming { stopStreaming() }

        // Preserve the path we're about to fork away from.
        snapshotBranch(divergingAt: index, label: "Before edit")

        // Truncate to and including the edited message, with updated content
        var updatedMessage = conversation.messages[index]
        updatedMessage.content = newContent
        conversation.messages = Array(conversation.messages[..<index]) + [updatedMessage]
        conversation.updatedAt = Date()
        dataStore.saveConversation(conversation)

        generationService.start(conversationID: conversation.id)
    }

    /// Regenerate an AI response: remove the AI message (and anything after it) and re-prompt.
    private func regenerate(from message: ChatMessage) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }

        if isStreaming { stopStreaming() }

        var carryVariants: [String]?
        if index == conversation.messages.count - 1 {
            // Re-rolling the latest answer: keep the existing answer(s) as
            // switchable variants of this turn (the ‹ i/n › navigator).
            carryVariants = message.variants ?? [message.content]
            conversation.messages = Array(conversation.messages[..<index])
        } else {
            // Mid-conversation: the tail below would be invalidated, so snapshot
            // the whole path and truncate instead of making per-turn variants.
            snapshotBranch(divergingAt: index, label: "Before regenerate")
            conversation.messages = Array(conversation.messages[..<index])
        }
        conversation.updatedAt = Date()
        dataStore.saveConversation(conversation)

        generationService.start(conversationID: conversation.id, carryVariants: carryVariants)
    }

    /// Switch which stored variant of an assistant turn is displayed.
    private func selectVariant(for message: ChatMessage, index: Int) {
        guard let i = conversation.messages.firstIndex(where: { $0.id == message.id }),
              let variants = conversation.messages[i].variants,
              index >= 0, index < variants.count else { return }
        conversation.messages[i].activeVariantIndex = index
        conversation.messages[i].content = variants[index]
        conversation.updatedAt = Date()
        dataStore.saveConversation(conversation)
    }

    // MARK: - Branches

    /// Save the current message list as a recoverable branch before a fork
    /// (edit or regenerate) discards part of it. No-op when nothing is lost.
    private func snapshotBranch(divergingAt index: Int, label: String) {
        guard index < conversation.messages.count else { return }
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        conversation.branches.append(ConversationBranch(label: "\(label) · \(stamp)", messages: conversation.messages))
        // Keep only the most recent few so a long editing session can't bloat
        // the on-disk conversation.
        if conversation.branches.count > 10 {
            conversation.branches.removeFirst(conversation.branches.count - 10)
        }
    }

    /// Load a saved branch, first stashing the current path so the switch is
    /// itself reversible.
    private func restoreBranch(_ branch: ConversationBranch) {
        if isStreaming { stopStreaming() }
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        let currentMessages = conversation.messages
        conversation.branches.removeAll { $0.id == branch.id }
        conversation.branches.append(ConversationBranch(label: "Replaced · \(stamp)", messages: currentMessages))
        if conversation.branches.count > 10 {
            conversation.branches.removeFirst(conversation.branches.count - 10)
        }
        conversation.messages = branch.messages
        conversation.updatedAt = Date()
        showingBranches = false
    }

    private func deleteBranch(_ branch: ConversationBranch) {
        conversation.branches.removeAll { $0.id == branch.id }
    }

    /// Opens the side-by-side compare sheet for an assistant message, capturing
    /// the same prior context that produced it so a different model answers the
    /// identical prompt. The result is non-destructive until the user chooses.
    private func startComparison(for message: ChatMessage) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }
        let contextLimit = UserDefaults.standard.integer(forKey: "contextMessageLimit")
        let limit = contextLimit > 0 ? contextLimit : 10
        let context = Array(conversation.messages[..<index].suffix(limit))
        comparison = ModelComparisonRequest(
            messageID: message.id,
            contextMessages: context,
            systemPrompt: generationService.resolvedSystemPrompt(for: conversation, agent: currentAgent),
            originalContent: message.content
        )
    }

    private func stopStreaming() {
        generationService.stop(conversationID: conversation.id)
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(AppTheme.Animations.quick) {
            if isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastMessage = conversation.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
    
    // Cycles through previously sent prompts
    private func navigateHistory(up: Bool) {
        let userMessages = conversation.messages.filter { $0.role == .user }
        guard !userMessages.isEmpty else { return }
        
        if up {
            if historyOffset < userMessages.count {
                historyOffset += 1
                inputText = userMessages[userMessages.count - historyOffset].content
            }
        } else {
            if historyOffset > 1 {
                historyOffset -= 1
                inputText = userMessages[userMessages.count - historyOffset].content
            } else if historyOffset == 1 {
                historyOffset = 0
                inputText = ""
            }
        }
    }
    
    // Reads an image from the clipboard if one exists
    private func pasteImageFromClipboard() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            
            isProcessingImage = true
            Task { @MainActor in
                let optimizedData = optimizeImageForAI(image)
                self.attachedImageData = optimizedData
                self.isProcessingImage = false
            }
        } else if let string = pasteboard.string(forType: .string) {
            // Fallback: If it's just text, paste the text normally
            inputText += string
        }
        #endif
    }
    
    // MARK: - Export

    enum ExportFormat {
        case markdown, json, plainText, html, pdf

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .json: return "json"
            case .plainText: return "txt"
            case .html: return "html"
            case .pdf: return "pdf"
            }
        }

        var utType: UTType {
            switch self {
            case .markdown: return .text
            case .json: return .json
            case .plainText: return .plainText
            case .html: return .html
            case .pdf: return .pdf
            }
        }
    }

    private func exportChat(as format: ExportFormat) {
        let safeTitle = conversation.title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [format.utType]
        savePanel.nameFieldStringValue = "\(safeTitle).\(format.fileExtension)"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            if format == .pdf {
                self.exportPDF(to: url)
            } else {
                let content: String
                switch format {
                case .markdown: content = self.renderMarkdown()
                case .json: content = self.renderJSON()
                case .plainText: content = self.renderPlainText()
                case .html: content = self.renderHTML()
                case .pdf: return
                }
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func exportPDF(to url: URL) {
        let html = renderHTML()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100))
        let coordinator = PDFExportCoordinator(targetURL: url)
        webView.navigationDelegate = coordinator
        // Retain the coordinator until the navigation completes
        objc_setAssociatedObject(webView, &PDFExportCoordinator.associationKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func renderMarkdown() -> String {
        var output = "# \(conversation.title)\n\n"
        output += "_Exported \(Date().formatted(date: .abbreviated, time: .shortened))_\n\n---\n\n"
        for message in conversation.messages {
            let roleName = message.role == .user ? "You" : "LocalMind"
            output += "### \(roleName)\n\n\(message.content)\n\n"
        }
        return output
    }

    private func renderPlainText() -> String {
        var output = "\(conversation.title)\n\(String(repeating: "=", count: conversation.title.count))\n\n"
        for message in conversation.messages {
            let roleName = message.role == .user ? "YOU" : "LOCALMIND"
            output += "[\(roleName)]\n\(message.content)\n\n"
        }
        return output
    }

    private func renderJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(conversation),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func renderHTML() -> String {
        let escapedTitle = conversation.title.htmlEscaped
        var body = ""
        for message in conversation.messages {
            let role = message.role == .user ? "user" : "assistant"
            let label = message.role == .user ? "You" : "LocalMind"
            body += """
            <div class="message \(role)">
              <div class="role">\(label)</div>
              <div class="content">\(message.content.htmlEscaped.replacingOccurrences(of: "\n", with: "<br>"))</div>
            </div>

            """
        }
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>\(escapedTitle)</title>
          <style>
            /* Force light, print-friendly styling regardless of the renderer's
               color scheme so exported PDFs are readable on paper. */
            :root { color-scheme: light; }
            body { font-family: -apple-system, system-ui, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 20px; background: #ffffff; color: #1d1d1f; line-height: 1.6; }
            h1 { font-weight: 600; color: #000; }
            .message { margin: 24px 0; page-break-inside: avoid; }
            .role { font-size: 13px; font-weight: 600; color: #6e6e73; margin-bottom: 4px; }
            .user .content { background: #f0f3f9; padding: 12px 16px; border-radius: 12px; color: #1d1d1f; }
            .assistant .content { padding: 4px 0; color: #1d1d1f; }
            @media print {
              body { margin: 0; padding: 24px; }
              .message { page-break-inside: avoid; }
            }
          </style>
        </head>
        <body>
          <h1>\(escapedTitle)</h1>
          \(body)
        </body>
        </html>
        """
    }
    

    // MARK: - Draft Recovery

    private func restoreDraft() {
        let key = "draft_\(conversation.id.uuidString)"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            inputText = saved
        }
    }

    private func clearDraft() {
        UserDefaults.standard.removeObject(forKey: "draft_\(conversation.id.uuidString)")
    }

    private func dictationAttributedString(prefix: String, space: String, dictated: String) -> AttributedString {
        var result = AttributedString(prefix)
        result.foregroundColor = AppTheme.Colors.textPrimary
        result += AttributedString(space)
        var dictatedPart = AttributedString(dictated)
        dictatedPart.foregroundColor = AppTheme.Colors.textTertiary
        result += dictatedPart
        return result
    }

    // MARK: - File Attachment
    
    private func pickFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.image, .pdf, .plainText]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.title = "Select a file to attach"
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            Task { @MainActor in
                do {
                    let fileExtension = url.pathExtension.lowercased()
                    
                    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .image) {
                        if let nsImage = NSImage(contentsOf: url) {
                            self.isProcessingImage = true
                            let optimizedData = optimizeImageForAI(nsImage)
                            self.attachedImageData = optimizedData
                            self.isProcessingImage = false
                        }
                        return
                    }
                    
                    var extractedText = ""
                    
                    if fileExtension == "pdf" {
                        if let pdfDocument = PDFDocument(url: url) {
                            extractedText = (0..<pdfDocument.pageCount).compactMap { pdfDocument.page(at: $0)?.string }.joined(separator: "\n")
                        }
                    } else {
                        extractedText = try String(contentsOf: url, encoding: .utf8)
                    }
                    
                    if !extractedText.isEmpty {
                        if !self.inputText.isEmpty { self.inputText += "\n\n" }
                        self.inputText += "📄 \(url.lastPathComponent):\n```\n\(extractedText)\n```\n"
                    }
                } catch {
                    print("Failed to read selected file: \(error)")
                }
            }
        }
    }
}

// MARK: - HTML Escaping

private extension String {
    var htmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// MARK: - Image Optimization Helper

/// Aggressively resizes images so they process near-instantly when sent to Local Vision models.
@MainActor
private func optimizeImageForAI(_ image: NSImage) -> Data? {
    let maxDimension: CGFloat = 800.0 // Vision models don't need 4K images
    var targetSize = image.size
    
    // Calculate new aspect-ratio-preserved size if it's too big
    if targetSize.width > maxDimension || targetSize.height > maxDimension {
        let ratio = min(maxDimension / targetSize.width, maxDimension / targetSize.height)
        targetSize = NSSize(width: targetSize.width * ratio, height: targetSize.height * ratio)
    }
    
    let newImage = NSImage(size: targetSize)
    newImage.lockFocus()
    // Draw the image scaled down
    image.draw(in: NSRect(origin: .zero, size: targetSize),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy,
               fraction: 1.0)
    newImage.unlockFocus()
    
    guard let tiff = newImage.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    
    // Compress it aggressively (0.6 is plenty for AI extraction)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
}

#if os(macOS)
final class PDFExportCoordinator: NSObject, WKNavigationDelegate {
    static var associationKey: UInt8 = 0
    let targetURL: URL

    init(targetURL: URL) {
        self.targetURL = targetURL
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKPDFConfiguration()
        webView.createPDF(configuration: config) { [targetURL] result in
            switch result {
            case .success(let data):
                try? data.write(to: targetURL)
            case .failure(let error):
                print("PDF export failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif

struct SystemPromptEditor: View {
    @State private var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(initial: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Prompt Override")
                        .font(AppTheme.Typography.headline)
                    Text("Leave empty to use the global default. Saves with this conversation only.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppTheme.Colors.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
            HStack {
                Button("Reset to default") { text = "" }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 520, height: 420)
    }
}

// MARK: - Model Comparison

/// Captures everything needed to reproduce an assistant turn under a different
/// model, without mutating the conversation until the user commits a choice.
struct ModelComparisonRequest: Identifiable {
    let id = UUID()
    let messageID: UUID
    let contextMessages: [ChatMessage]
    let systemPrompt: String
    let originalContent: String
}

/// Side-by-side comparison: the existing answer on the left, a freshly streamed
/// answer from a chosen model on the right. The user keeps one or the other.
struct ModelCompareView: View {
    let request: ModelComparisonRequest
    let aiManager: AIServiceManager
    let candidateModels: [String]
    let onReplace: (String) -> Void
    let onClose: () -> Void

    @State private var selectedModel: String = ""
    @State private var altContent: String = ""
    @State private var isGenerating = false
    @State private var didFinish = false
    @State private var genTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare Models")
                        .font(AppTheme.Typography.headline)
                    Text("Answer the same prompt with another model, then keep the one you prefer.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                if candidateModels.isEmpty {
                    Text("The active backend exposes no selectable models to compare against.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $selectedModel) {
                        ForEach(candidateModels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)

                    Button(isGenerating ? "Generating…" : (didFinish ? "Regenerate" : "Generate")) {
                        generate()
                    }
                    .disabled(isGenerating || selectedModel.isEmpty)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 0) {
                compareColumn(title: "Current answer", text: request.originalContent, accent: false, showSpinner: false)
                Divider()
                compareColumn(
                    title: selectedModel.isEmpty ? "Alternative" : selectedModel,
                    text: altContent.isEmpty && !isGenerating ? "Press Generate to produce an alternative." : altContent,
                    accent: true,
                    showSpinner: isGenerating && altContent.isEmpty
                )
            }
            .frame(maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8).stroke(AppTheme.Colors.border, lineWidth: 1)
            }

            HStack {
                Spacer()
                Button("Keep current", action: onClose)
                Button("Use alternative") { onReplace(altContent) }
                    .buttonStyle(.borderedProminent)
                    .disabled(altContent.isEmpty || isGenerating || !didFinish)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 820, height: 560)
        .onAppear { selectedModel = candidateModels.first ?? "" }
        .onDisappear { genTask?.cancel() }
    }

    private func compareColumn(title: String, text: String, accent: Bool, showSpinner: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textSecondary)
                .lineLimit(1)
            ScrollView {
                if showSpinner {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Generating…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MessageMarkdownView(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func generate() {
        genTask?.cancel()
        altContent = ""
        isGenerating = true
        didFinish = false
        let model = selectedModel
        genTask = Task {
            guard let service = aiManager.currentService else {
                isGenerating = false
                return
            }
            do {
                for try await chunk in service.streamChat(
                    messages: request.contextMessages,
                    systemPrompt: request.systemPrompt,
                    modelOverride: model,
                    parameters: aiManager.aiParameters,
                    tools: nil
                ) {
                    if Task.isCancelled { break }
                    if case .text(let text) = chunk { altContent += text }
                }
            } catch {
                altContent += "\n\n⚠️ \(error.localizedDescription)"
            }
            isGenerating = false
            didFinish = true
        }
    }
}
