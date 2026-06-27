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
    @Binding var conversation: Conversation
    
    @State private var inputText = ""
    @State private var isStreaming = false
    @State private var streamingContent = ""
    @State private var currentStreamTask: Task<Void, Never>?
    @State private var scrollProxy: ScrollViewProxy?
    
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isInputFocused = true
            }
        }
        .onChange(of: inputText) { _, newValue in
            draftSaveTask?.cancel()
            draftSaveTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(newValue, forKey: "draft_\(conversation.id.uuidString)")
            }
        }
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
    }

    /// Hybrid token estimate: word count × 1.33 for natural language,
    /// plus char/4 for non-word characters (punctuation, code symbols).
    /// Matches GPT-style BPE counts within ~10% for both prose and code.
    private var tokenCountLabel: String {
        let full = conversation.messages.map(\.content).joined(separator: " ")
        let tokens = TokenEstimator.estimate(full)
        if tokens >= 1000 {
            return "\(String(format: "%.1f", Double(tokens) / 1000))k tokens"
        }
        return "\(tokens) tokens"
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
                            onRegenerate: message.role == .assistant ? { regenerate(from: message) } : nil
                        )
                        .id(message.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if isStreaming && !streamingContent.isEmpty {
                        MessageBubble(
                            message: ChatMessage(role: .assistant, content: streamingContent),
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
    
    // MARK: - Welcome Layout (centered input like ChatGPT/Claude)

    private var welcomeLayout: some View {
        VStack(spacing: 0) {
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

                    // Send button
                    Button {
                        if isStreaming { stopStreaming() } else { sendMessage() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(canSend || isStreaming ? AppTheme.Colors.accentPrimary : AppTheme.Colors.backgroundTertiary)
                            Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(canSend || isStreaming ? .white : AppTheme.Colors.textTertiary)
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
        
        currentStreamTask = Task {
            await generateResponse()
        }
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
                    parameters: aiManager.aiParameters
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
                    parameters: aiManager.aiParameters
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
    
    private func generateResponse() async {
        guard let service = aiManager.currentService else {
            let errorMsg = ChatMessage(role: .assistant, content: "⚠️ \(AIServiceError.noBackendAvailable.localizedDescription)\n\n💡 \(AIServiceError.noBackendAvailable.recoverySuggestion ?? "")")
            conversation.messages.append(errorMsg)
            dataStore.saveConversation(conversation)
            return
        }
        
        isStreaming = true
        streamingContent = ""
        
        var systemPrompt = UserDefaults.standard.string(forKey: "defaultSystemPrompt") ?? "You are LocalMind, a helpful, concise AI assistant. Provide clear, actionable responses. Use markdown formatting when appropriate."
        if systemPrompt.isEmpty {
            systemPrompt = "You are LocalMind, a helpful, concise AI assistant. Provide clear, actionable responses. Use markdown formatting when appropriate."
        }
        
        if let customToolID = conversation.customToolID,
           let customTool = dataStore.customTools.first(where: { $0.id == customToolID }) {
            systemPrompt = customTool.systemPrompt
        }
        
        // Apply context limit
        let contextLimit = UserDefaults.standard.integer(forKey: "contextMessageLimit")
        let limit = contextLimit > 0 ? contextLimit : 10
        let recentMessages = Array(conversation.messages.suffix(limit))
        
        do {
            for try await chunk in service.streamChat(messages: recentMessages, systemPrompt: systemPrompt, modelOverride: nil, parameters: aiManager.aiParameters) {
                if Task.isCancelled { break }
                streamingContent += chunk
            }
            
            if !streamingContent.isEmpty {
                let assistantMessage = ChatMessage(role: .assistant, content: streamingContent)
                conversation.messages.append(assistantMessage)
                conversation.updatedAt = Date()
                dataStore.saveConversation(conversation)
                
                if UserDefaults.standard.bool(forKey: "autoReadResponses") {
                    voiceManager.speak(text: assistantMessage.content)
                }
            }
        } catch {
            if !Task.isCancelled {
                let description: String
                if let serviceError = error as? AIServiceError {
                    description = "⚠️ \(serviceError.localizedDescription)\n\n💡 \(serviceError.recoverySuggestion ?? "")"
                } else if (error as NSError).code == NSURLErrorTimedOut {
                    let timeout = AIServiceError.timeout
                    description = "⚠️ \(timeout.localizedDescription)\n\n💡 \(timeout.recoverySuggestion ?? "")"
                } else {
                    description = "⚠️ Error: \(error.localizedDescription)"
                }
                let errorMsg = ChatMessage(role: .assistant, content: description)
                conversation.messages.append(errorMsg)
                dataStore.saveConversation(conversation)
            }
        }
        
        streamingContent = ""
        isStreaming = false
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

        // Truncate to and including the edited message, with updated content
        var updatedMessage = conversation.messages[index]
        updatedMessage.content = newContent
        conversation.messages = Array(conversation.messages[..<index]) + [updatedMessage]
        conversation.updatedAt = Date()
        dataStore.saveConversation(conversation)

        currentStreamTask = Task { await generateResponse() }
    }

    /// Regenerate an AI response: remove the AI message (and anything after it) and re-prompt.
    private func regenerate(from message: ChatMessage) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }

        if isStreaming { stopStreaming() }

        // Drop the AI message and everything after it
        conversation.messages = Array(conversation.messages[..<index])
        conversation.updatedAt = Date()
        dataStore.saveConversation(conversation)

        currentStreamTask = Task { await generateResponse() }
    }

    private func stopStreaming() {
        currentStreamTask?.cancel()
        
        if !streamingContent.isEmpty {
            let partialMessage = ChatMessage(role: .assistant, content: streamingContent + "\n\n*[Generation stopped]*")
            conversation.messages.append(partialMessage)
            conversation.updatedAt = Date()
            dataStore.saveConversation(conversation)
        }
        
        streamingContent = ""
        isStreaming = false
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
            body { font-family: -apple-system, system-ui, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 20px; color: #1d1d1f; line-height: 1.6; }
            h1 { font-weight: 600; }
            .message { margin: 24px 0; }
            .role { font-size: 13px; font-weight: 600; color: #6e6e73; margin-bottom: 4px; }
            .user .content { background: rgba(0, 122, 255, 0.08); padding: 12px 16px; border-radius: 12px; }
            .assistant .content { padding: 4px 0; }
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
