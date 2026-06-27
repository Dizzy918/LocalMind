//
//  QuickActionPanel.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Floating menu bar panel for quick AI actions
struct QuickActionPanel: View {
    let aiManager: AIServiceManager
    let dataStore: DataStore // Added to save conversations
    
    // Environment action to reliably reopen the main app window
    @Environment(\.openWindow) private var openWindow
    
    @State private var inputText = ""
    @State private var resultText = ""
    @State private var isGenerating = false
    @State private var currentTask: Task<Void, Never>?
    @State private var showCopied = false
    
    @State private var currentConversation: Conversation?
    
    @FocusState private var isInputFocused: Bool
    
    // Binds directly to UserDefaults so it syncs with AIServiceManager
    @AppStorage("selectedOllamaModel") private var selectedOllamaModel: String = "qwen3:8b"
    
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    
    // Dynamically finds the last active conversation
    private var recentConversation: Conversation? {
        dataStore.conversations
            .filter { !$0.messages.isEmpty && $0.title != "New Conversation" }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search / Input bar
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(isGenerating ? AppTheme.Colors.textTertiary : AppTheme.Colors.accentPrimary)
                    .symbolEffect(.bounce, value: isGenerating)
                
                TextField("Ask LocalMind...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .focused($isInputFocused)
                    .onSubmit {
                        if !inputText.isEmpty {
                            processInput()
                        }
                    }
                
                if !inputText.isEmpty || !resultText.isEmpty {
                    Button {
                        inputText = ""
                        resultText = ""
                        currentConversation = nil // Reset for next time
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppTheme.Spacing.lg)
            .background(AppTheme.Colors.backgroundSecondary)
            
            Divider().overlay(AppTheme.Colors.divider)
            
            // Result area
            if !resultText.isEmpty || isGenerating {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    ScrollView {
                        Text(resultText)
                            .font(AppTheme.Typography.body)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 300)
                    
                    if !resultText.isEmpty && !isGenerating {
                        HStack {
                            Spacer()
                            Button {
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(resultText, forType: .string)
                                #else
                                UIPasteboard.general.string = resultText
                                #endif
                                
                                showCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    showCopied = false
                                }
                            } label: {
                                HStack(spacing: AppTheme.Spacing.xs) {
                                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                    Text(showCopied ? "Copied" : "Copy")
                                }
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(showCopied ? AppTheme.Colors.accentGreen : AppTheme.Colors.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(AppTheme.Spacing.lg)
                .background(AppTheme.Colors.backgroundPrimary)
            } else {
                // Quick hints
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("QUICK ACTIONS")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .tracking(1.2)
                    
                    if let convo = recentConversation {
                        quickHint("Continue: \(convo.title)", icon: "arrow.uturn.forward") {
                            loadConversation(convo)
                            isInputFocused = true
                        }
                        
                        quickHint("Summarize this discussion", icon: "doc.text") {
                            loadConversation(convo)
                            inputText = "Please provide a brief summary of our discussion so far."
                            processInput()
                        }
                        
                        quickHint("Extract key takeaways", icon: "list.bullet") {
                            loadConversation(convo)
                            inputText = "What are the key takeaways and action items from this conversation?"
                            processInput()
                        }
                    } else {
                        // Fallback actions if there's no chat history
                        quickHint("Summarize copied text", icon: "doc.text") {
                            if let clipboard = getClipboard() {
                                inputText = "Summarize this: " + clipboard
                                processInput()
                            }
                        }
                        
                        quickHint("Fix clipboard grammar", icon: "text.badge.checkmark") {
                            if let clipboard = getClipboard() {
                                inputText = "Fix the grammar and spelling of this text: " + clipboard
                                processInput()
                            }
                        }
                        
                        quickHint("Draft a polite reply", icon: "envelope") {
                            inputText = "Draft a polite reply to this: "
                            isInputFocused = true
                        }
                    }
                }
                .padding(AppTheme.Spacing.lg)
                .background(AppTheme.Colors.backgroundPrimary)
            }
            
            Divider().overlay(AppTheme.Colors.divider)
            
            // Bottom Status / Settings Bar
            HStack(spacing: AppTheme.Spacing.md) {
                // App Options Menu
                Menu {
                    // Using a Thin Space (\u{2009}) to separate the l and M visually in system menus!
                    Button("Show Local\u{2009}Mind") {
                        openMainApp()
                    }
                    Divider()
                    Button("Quit Local\u{2009}Mind") {
                        #if os(macOS)
                        // Wrapping in async ensures the menu closes before we terminate
                        DispatchQueue.main.async {
                            NSApplication.shared.terminate(nil)
                        }
                        #endif
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                
                Button {
                    isDarkMode.toggle()
                } label: {
                    Image(systemName: isDarkMode ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .fixedSize()
                
                if aiManager.currentBackend == .ollama && !aiManager.availableModels.isEmpty {
                    Picker("", selection: $selectedOllamaModel) {
                        ForEach(aiManager.availableModels, id: \.name) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                    .onChange(of: selectedOllamaModel) { _, _ in
                        Task {
                            await aiManager.detectAndConnect()
                        }
                    }
                } else {
                    Text(aiManager.statusMessage)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
                
                Spacer()
                
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(AppTheme.Colors.backgroundTertiary)
        }
        .frame(width: 450)
        .background(AppTheme.Colors.backgroundPrimary)
        .onAppear {
            isInputFocused = true
            Task {
                if aiManager.currentService == nil {
                    await aiManager.detectAndConnect()
                }
            }
        }
    }
    
    private func quickHint(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .frame(width: 20)
                Text(title)
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1) // Prevents long topic names from breaking the UI
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }
            .padding(.vertical, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func loadConversation(_ convo: Conversation) {
        currentConversation = convo
        // Display the last AI response to give the user context
        if let lastAssistantMessage = convo.messages.last(where: { $0.role == .assistant }) {
            resultText = lastAssistantMessage.content
        } else if let lastUserMessage = convo.messages.last(where: { $0.role == .user }) {
            resultText = "You: \(lastUserMessage.content)\n\n(Waiting for reply...)"
        }
    }
    
    private func getClipboard() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return UIPasteboard.general.string
        #endif
    }
    
    private func processInput() {
        guard let service = aiManager.currentService else {
            resultText = "⚠️ AI backend is not available. Please check settings."
            return
        }
        
        let prompt = inputText
        inputText = "" // Clear the input text immediately
        
        currentTask?.cancel()
        isGenerating = true
        
        // If this is the start of a new interaction, clear out the result and initialize a conversation
        if currentConversation == nil {
            resultText = ""
            currentConversation = Conversation(toolType: .chat)
        } else if resultText != "" && !resultText.starts(with: "⚠️") {
            // Clear result text if we are just continuing an old chat so it doesn't mesh old and new text
            resultText = ""
        }
        
        // Save the user's message to the conversation
        let userMessage = ChatMessage(role: .user, content: prompt)
        currentConversation?.messages.append(userMessage)
        currentConversation?.updateTitleIfNeeded()
        currentConversation?.updatedAt = Date()
        
        if let convo = currentConversation {
            dataStore.saveConversation(convo)
        }
        
        currentTask = Task {
            do {
                // Pass the full conversation history to the model so it remembers the context
                let history = currentConversation?.messages ?? [userMessage]
                
                for try await chunk in service.streamChat(
                    messages: history,
                    systemPrompt: "You are a quick menu bar assistant. Provide very concise, direct answers. Do not use filler words.",
                    modelOverride: nil,
                    parameters: aiManager.aiParameters,
                    tools: nil
                ) {
                    if Task.isCancelled { break }
                    if case .text(let t) = chunk { resultText += t }
                }
                
                // When finished generating, save the AI's response to the conversation
                if !Task.isCancelled && !resultText.isEmpty {
                    let aiMessage = ChatMessage(role: .assistant, content: resultText)
                    currentConversation?.messages.append(aiMessage)
                    currentConversation?.updatedAt = Date()
                    
                    if let convo = currentConversation {
                        dataStore.saveConversation(convo)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    resultText += "\n\n⚠️ Error: \(error.localizedDescription)"
                }
            }
            
            isGenerating = false
        }
    }
    
    private func openMainApp() {
        #if os(macOS)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Uses SwiftUI environment API to guarantee the window opens, even if it was closed
        openWindow(id: "main")
        #endif
    }
}
