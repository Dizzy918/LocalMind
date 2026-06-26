//
//  SidebarView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case chat
    case customTool(String)
}

/// Main sidebar with tool navigation and conversation history
struct SidebarView: View {
    @Binding var selectedSelection: SidebarSelection
    @Binding var selectedConversationID: UUID?
    @Binding var isCompact: Bool
    
    let dataStore: DataStore
    let aiManager: AIServiceManager
    let onNewConversation: () -> Void
    
    @Environment(\.openSettings) private var openSettingsAction
    
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @State private var searchQuery = ""
    @State private var isSearching = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // App Header
            appHeader
            
            Divider()
                .overlay(AppTheme.Colors.divider)
            
            // Tool Selector
            toolSelector
            
            Divider()
                .overlay(AppTheme.Colors.divider)
            
            // Conversation History
            conversationList
            
            Spacer()
            
            Divider()
                .overlay(AppTheme.Colors.divider)
            
            // Status Footer
            statusFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Colors.sidebarBackground)
    }
    
    // MARK: - App Header
    
    private var appHeader: some View {
        HStack(spacing: isCompact ? 0 : AppTheme.Spacing.md) {
            if isCompact { Spacer(minLength: 0) }
            
            Image(systemName: "brain.head.profile")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(AppTheme.Colors.accentGradient)
            
            if !isCompact {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("LocalMind")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    
                    Text("Your private AI assistant")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            } else {
                Spacer(minLength: 0)
            }
            
            // Custom Sidebar Toggle Button
            HoverIconButton(
                systemName: "sidebar.left",
                size: isCompact ? 18 : 16,
                baseColor: isCompact ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textSecondary,
                hoverColor: isCompact ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textPrimary,
                helpText: isCompact ? "Expand Sidebar" : "Collapse Sidebar"
            ) {
                isCompact.toggle()
            }
            
            if isCompact { Spacer(minLength: 0) }
        }
        .padding(.horizontal, isCompact ? AppTheme.Spacing.xs : AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.lg)
    }
    
    // MARK: - Tool Selector
    
    private var toolSelector: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            if !isCompact {
                HStack {
                    Text("TOOLS")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .tracking(1.2)
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.top, AppTheme.Spacing.md)
            } else {
                Spacer().frame(height: AppTheme.Spacing.md)
            }
            
            ToolButton(
                icon: ToolType.chat.icon,
                displayName: "Chat",
                isSelected: selectedSelection == .chat,
                isCompact: isCompact
            ) {
                withAnimation(AppTheme.Animations.spring) {
                    selectedSelection = .chat
                    selectedConversationID = nil
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            
            ForEach(dataStore.customTools) { customTool in
                ToolButton(
                    icon: customTool.icon,
                    displayName: customTool.name,
                    isSelected: selectedSelection == .customTool(customTool.id),
                    isCompact: isCompact
                ) {
                    withAnimation(AppTheme.Animations.spring) {
                        selectedSelection = .customTool(customTool.id)
                        selectedConversationID = nil
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
            }
        }
        .padding(.bottom, AppTheme.Spacing.md)
    }
    
    // MARK: - Conversation List
    
    private var conversationList: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            if !isCompact {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if isSearching {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                            TextField("Search...", text: $searchQuery)
                                .textFieldStyle(.plain)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .focused($isSearchFocused)
                        }

                        Button {
                            withAnimation(AppTheme.Animations.quick) {
                                searchQuery = ""
                                isSearching = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("RECENT")
                            .font(AppTheme.Typography.captionSecondary)
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                            .tracking(1.2)

                        Spacer()

                        HoverIconButton(
                            systemName: "magnifyingglass",
                            size: 12,
                            baseColor: AppTheme.Colors.textTertiary,
                            hoverColor: AppTheme.Colors.textPrimary,
                            helpText: "Search"
                        ) {
                            withAnimation(AppTheme.Animations.quick) {
                                isSearching = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isSearchFocused = true
                            }
                        }

                        HoverIconButton(
                            systemName: "plus.circle.fill",
                            size: 16,
                            baseColor: AppTheme.Colors.textTertiary,
                            hoverColor: AppTheme.Colors.accentPrimary,
                            helpText: "New conversation",
                            action: onNewConversation
                        )
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.top, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.xs)
            } else {
                HoverIconButton(
                    systemName: "plus.circle.fill",
                    size: 16,
                    baseColor: AppTheme.Colors.textTertiary,
                    hoverColor: AppTheme.Colors.accentPrimary,
                    helpText: "New conversation",
                    action: onNewConversation
                )
                .padding(.top, AppTheme.Spacing.md)
            }

            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.xxs) {
                    let conversations = searchQuery.isEmpty
                        ? dataStore.conversationsForSelection(selectedSelection)
                        : dataStore.searchConversations(query: searchQuery)

                    if conversations.isEmpty {
                        if !isCompact {
                            Text(searchQuery.isEmpty ? "No conversations yet" : "No results found")
                                .font(AppTheme.Typography.captionSecondary)
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                                .padding(.top, AppTheme.Spacing.xl)
                        }
                    } else {
                        ForEach(conversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isSelected: selectedConversationID == conversation.id,
                                isCompact: isCompact
                            ) {
                                withAnimation(AppTheme.Animations.quick) {
                                    selectedConversationID = conversation.id
                                }
                            }
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .contextMenu {
                                Button {
                                    dataStore.togglePin(conversation)
                                } label: {
                                    Label(conversation.isPinned ? "Unpin" : "Pin to top",
                                          systemImage: conversation.isPinned ? "pin.slash" : "pin")
                                }

                                Button {
                                    dataStore.toggleArchive(conversation)
                                } label: {
                                    Label(conversation.isArchived ? "Unarchive" : "Archive",
                                          systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    dataStore.deleteConversation(conversation)
                                    if selectedConversationID == conversation.id {
                                        selectedConversationID = nil
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, AppTheme.Spacing.md)
            }
        }
    }
    
    // MARK: - Status Footer
    
    private var statusFooter: some View {
        Group {
            if isCompact {
                VStack(spacing: AppTheme.Spacing.lg) {
                    StatusBadge(
                        backend: aiManager.currentBackend,
                        statusMessage: aiManager.statusMessage,
                        isCompact: true
                    )
                    
                    HoverIconButton(
                        systemName: isDarkMode ? "moon.fill" : "sun.max.fill",
                        size: 14,
                        baseColor: AppTheme.Colors.textTertiary,
                        hoverColor: AppTheme.Colors.textPrimary,
                        helpText: isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode"
                    ) {
                        isDarkMode.toggle()
                    }
                    
                    settingsButton(size: 14)
                }
                .padding(.vertical, AppTheme.Spacing.md)
            } else {
                HStack(spacing: AppTheme.Spacing.sm) {
                    StatusBadge(
                        backend: aiManager.currentBackend,
                        statusMessage: aiManager.statusMessage,
                        isCompact: false
                    )
                    
                    // Model Changer for Ollama
                    if aiManager.currentBackend == .ollama && !aiManager.availableModels.isEmpty {
                        Picker("", selection: Binding(
                            get: { aiManager.selectedOllamaModel },
                            set: { newValue in
                                aiManager.selectedOllamaModel = newValue
                                Task { await aiManager.detectAndConnect() }
                            }
                        )) {
                            ForEach(aiManager.availableModels, id: \.name) { model in
                                Text(model.name).tag(model.name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: 120)
                    }
                    
                    // Model Changer for OpenAI-compatible
                    if aiManager.currentBackend == .openAICompatible && !aiManager.availableOpenAIModels.isEmpty {
                        Picker("", selection: Binding(
                            get: { aiManager.selectedOpenAIModel },
                            set: { newValue in
                                aiManager.selectedOpenAIModel = newValue
                                Task { await aiManager.detectAndConnect() }
                            }
                        )) {
                            ForEach(aiManager.availableOpenAIModels) { model in
                                Text(model.id).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: 120)
                    }
                    
                    Spacer()
                    
                    HoverIconButton(
                        systemName: isDarkMode ? "moon.fill" : "sun.max.fill",
                        size: 12,
                        baseColor: AppTheme.Colors.textTertiary,
                        hoverColor: AppTheme.Colors.textPrimary,
                        helpText: isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode"
                    ) {
                        isDarkMode.toggle()
                    }
                    
                    settingsButton(size: 12)
                }
                .padding(AppTheme.Spacing.md)
            }
        }
    }
    
    /// Opens the macOS Settings window
    private func openSettings() {
        if #available(macOS 13.0, *) {
            openSettingsAction()
        } else {
            #if os(macOS)
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            #endif
        }
        #if os(macOS)
        // Bring the app to front
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        #endif
    }
    
    @ViewBuilder
    private func settingsButton(size: CGFloat) -> some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                HoverIconLabel(systemName: "gearshape", size: size, helpText: "Settings")
            }
            .buttonStyle(.plain)
        } else {
            HoverIconButton(
                systemName: "gearshape",
                size: size,
                baseColor: AppTheme.Colors.textTertiary,
                hoverColor: AppTheme.Colors.textPrimary,
                helpText: "Settings"
            ) {
                openSettings()
            }
        }
    }
}

struct HoverIconLabel: View {
    let systemName: String
    let size: CGFloat
    let helpText: String
    
    @State private var isHovering = false
    
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size))
            .foregroundStyle(isHovering ? AppTheme.Colors.textPrimary : AppTheme.Colors.textTertiary)
            .padding(AppTheme.Spacing.xs)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                    .fill(isHovering ? AppTheme.Colors.hover : Color.clear)
            }
            .scaleEffect(isHovering ? 1.05 : 1.0)
            .help(helpText)
            .onHover { hovering in
                withAnimation(AppTheme.Animations.quick) {
                    isHovering = hovering
                }
            }
    }
}
