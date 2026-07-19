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
    let generationService: ChatGenerationService
    let onClose: () -> Void

    @State private var inputText = ""
    @State private var attachedImageData: Data?
    @State private var selectedConversationID: UUID?
    @FocusState private var inputIsFocused: Bool

    @AppStorage("isDarkMode") private var isDarkMode: Bool = true

    /// The bubble reflects the shared generation service, so an answer it
    /// started keeps streaming (and finishes) even after the bubble is hidden.
    private var activeConversation: Conversation? {
        guard let id = selectedConversationID else { return nil }
        return dataStore.conversations.first { $0.id == id }
    }

    private var isStreaming: Bool {
        guard let id = selectedConversationID else { return false }
        return generationService.isStreaming(id)
    }

    private var streamingContent: String {
        guard let id = selectedConversationID else { return "" }
        return generationService.streamingText(id)
    }

    /// The most recent assistant answer for the selected conversation, shown
    /// once streaming finishes so the bubble is useful on its own.
    private var latestAnswer: String? {
        activeConversation?.messages.last(where: { $0.role == .assistant })?.content
    }

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

                if selectedConversationID != nil {
                    HoverIconButton(
                        systemName: "arrow.up.right.square",
                        baseColor: AppTheme.Colors.textSecondary,
                        hoverColor: AppTheme.Colors.accentPrimary,
                        helpText: "Open in main window",
                        action: openInApp
                    )
                }

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

            // Answer / streaming area
            if isStreaming || latestAnswer != nil {
                ScrollView {
                    Text((isStreaming ? streamingContent : (latestAnswer ?? "")).strippingThinkBlocks)
                        .font(AppTheme.Typography.body)
                        .textSelection(.enabled)
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
                    .focused($inputIsFocused)
                    .onSubmit {
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            sendMessage()
                        }
                    }

                HoverIconButton(
                    systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill",
                    size: 24,
                    baseColor: inputText.isEmpty && !isStreaming ? AppTheme.Colors.textTertiary : AppTheme.Colors.accentPrimary,
                    hoverColor: AppTheme.Colors.accentPrimary,
                    helpText: isStreaming ? "Stop" : "Send message",
                    action: { isStreaming ? stopStreaming() : sendMessage() }
                )
                .disabled(inputText.isEmpty && !isStreaming)
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
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, aiManager.currentService != nil else { return }

        // Find or create the target conversation.
        var targetConversation: Conversation
        if let id = selectedConversationID, let existing = dataStore.conversations.first(where: { $0.id == id }) {
            targetConversation = existing
        } else {
            targetConversation = Conversation(toolType: .chat)
        }

        targetConversation.messages.append(ChatMessage(role: .user, content: text, imageData: attachedImageData))
        targetConversation.updateTitleIfNeeded()
        targetConversation.updatedAt = Date()
        dataStore.saveConversation(targetConversation)
        selectedConversationID = targetConversation.id

        inputText = ""
        attachedImageData = nil

        // Route through the shared service — the bubble gets agents, memory,
        // context management, and tools for free, and the answer survives the
        // bubble being hidden (unlike the old inline stream that died on close).
        generationService.start(conversationID: targetConversation.id)
    }

    private func stopStreaming() {
        guard let id = selectedConversationID else { return }
        generationService.stop(conversationID: id)
    }

    /// Hands the current conversation off to the main window and hides the bubble.
    private func openInApp() {
        guard let id = selectedConversationID else { return }
        NotificationCenter.default.post(name: .openConversation, object: id)
        NSApp.activate(ignoringOtherApps: true)
        onClose()
    }
}
