//
//  BubbleView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 23.06.26.
//

import SwiftUI
import AppKit

struct BubbleView: View {
    let aiManager: AIServiceManager
    let dataStore: DataStore
    let onClose: () -> Void
    
    @State private var inputText = ""
    @State private var attachedImageData: Data?
    @State private var attachedImageURL: URL?
    @State private var isAttachingFile = false
    @State private var selectedConversationID: UUID?
    @State private var isStreaming = false
    @State private var isInputFocused = false
    @FocusState private var inputIsFocused: Bool
    
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @State private var streamingContent = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Picker("Conversation", selection: $selectedConversationID) {
                    Text("New Conversation").tag(UUID?.none)
                    Divider()
                    ForEach(dataStore.conversations.prefix(10)) { conversation in
                        Text(conversation.title).tag(UUID?.some(conversation.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                
                Spacer()
                
                HoverIconButton(
                    systemName: "camera.viewfinder",
                    baseColor: attachedImageData != nil ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textSecondary,
                    hoverColor: AppTheme.Colors.accentPrimary,
                    helpText: "Take Screenshot",
                    action: takeScreenshot
                )
                
                HoverIconButton(
                    systemName: "xmark.circle.fill",
                    baseColor: AppTheme.Colors.textTertiary,
                    hoverColor: AppTheme.Colors.textPrimary,
                    helpText: "Close",
                    action: onClose
                )
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Colors.backgroundSecondary.opacity(0.8))
            
            Divider().overlay(AppTheme.Colors.divider)
            
            // Image Preview
            if let data = attachedImageData, let nsImage = NSImage(data: data) {
                HStack {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 60)
                        .cornerRadius(AppTheme.Dimensions.cornerRadiusSmall)
                    
                    HoverIconButton(
                        systemName: "xmark.circle.fill",
                        baseColor: AppTheme.Colors.textTertiary,
                        hoverColor: AppTheme.Colors.textPrimary,
                        helpText: "Remove Image"
                    ) {
                        attachedImageData = nil
                    }
                    
                    Spacer()
                }
                .padding(AppTheme.Spacing.md)
                .background(AppTheme.Colors.backgroundPrimary.opacity(0.8))
            }
            
            // Content Stream (if streaming)
            if isStreaming {
                ScrollView {
                    Text(streamingContent)
                        .font(AppTheme.Typography.body)
                        .padding(AppTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .background(AppTheme.Colors.backgroundPrimary.opacity(0.8))
                
                Divider().overlay(AppTheme.Colors.divider)
            }
            
            // Input Area
            HStack {
                TextField("Ask LocalMind...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Typography.body)
                    .lineLimit(1...5)
                    .onSubmit {
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            sendMessage()
                        }
                    }
                
                HoverIconButton(
                    systemName: "arrow.up.circle.fill",
                    size: 24,
                    baseColor: inputText.isEmpty ? AppTheme.Colors.textTertiary : AppTheme.Colors.accentPrimary,
                    hoverColor: AppTheme.Colors.accentPrimary,
                    helpText: "Send message",
                    action: sendMessage
                )
                .disabled(inputText.isEmpty || isStreaming)
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Colors.backgroundSecondary.opacity(0.8))
        }
        .background(AppTheme.Colors.backgroundPrimary.opacity(0.6))
        .cornerRadius(AppTheme.Dimensions.cornerRadiusLarge)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusLarge)
                .stroke(AppTheme.Colors.divider, lineWidth: 1)
        )
    }
    
    private func takeScreenshot() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("localmind_screenshot.jpg")
        
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-x", "-t", "jpg", tempURL.path]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if let data = try? Data(contentsOf: tempURL) {
                attachedImageData = data
            }
        } catch {
            print("Failed to take screenshot: \(error)")
        }
    }
    
    private func sendMessage() {
        guard !inputText.isEmpty, let service = aiManager.currentService else { return }
        
        // Find or create conversation
        var targetConversation: Conversation
        if let id = selectedConversationID, let existing = dataStore.conversations.first(where: { $0.id == id }) {
            targetConversation = existing
        } else {
            targetConversation = Conversation(toolType: .chat)
            selectedConversationID = targetConversation.id
        }
        
        let userMessage = ChatMessage(role: .user, content: inputText, imageData: attachedImageData)
        targetConversation.messages.append(userMessage)
        targetConversation.updateTitleIfNeeded()
        
        inputText = ""
        attachedImageData = nil
        isStreaming = true
        streamingContent = ""
        
        Task { @MainActor in
            do {
                for try await chunk in service.streamChat(messages: targetConversation.messages, systemPrompt: "You are LocalMind.", modelOverride: nil, parameters: aiManager.aiParameters) {
                    streamingContent += chunk
                }
                
                let aiMessage = ChatMessage(role: .assistant, content: streamingContent)
                targetConversation.messages.append(aiMessage)
                dataStore.saveConversation(targetConversation)
                
                isStreaming = false
                streamingContent = ""
                onClose() // Auto-close after completion
            } catch {
                streamingContent = "⚠️ Error: \(error.localizedDescription)"
                isStreaming = false
            }
        }
    }
}
