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
    case project(UUID)
}

/// Main sidebar with tool navigation and conversation history
struct SidebarView: View {
    @Binding var selectedSelection: SidebarSelection
    @Binding var selectedConversationID: UUID?
    @Binding var isCompact: Bool
    
    let dataStore: DataStore
    let aiManager: AIServiceManager
    let profileStore: ProfileStore
    let generationService: ChatGenerationService
    let onNewConversation: () -> Void

    @Environment(\.openSettings) private var openSettingsAction

    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @AppStorage("enableGlobalShortcut") private var globalShortcutEnabled: Bool = false
    @AppStorage(AppLayout.storageKey) private var layoutRaw: String = AppLayout.classic.rawValue
    private var layout: AppLayout { AppLayout(rawValue: layoutRaw) ?? .classic }
    @State private var searchQuery = ""
    @State private var isSearching = false
    @FocusState private var isSearchFocused: Bool
    @State private var mergeSource: Conversation?
    @State private var showingProfileMenu = false
    @State private var showingHelp = false
    @State private var editingProject: Project?
    @State private var isCreatingProject = false

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

            // Projects (workspaces with defaults)
            projectsSection

            // Conversation History
            conversationList

            Spacer()

            // Generation control: a chat streaming in the background is easy
            // to lose track of — surface the count with a kill switch. Shown
            // from one generation up so an off-screen stream is stoppable too.
            if !isCompact, generationService.activeGenerationCount >= 1 {
                HStack(spacing: AppTheme.Spacing.sm) {
                    PulsingDot(size: 6)
                    Text(generationService.activeGenerationCount == 1
                         ? "1 chat generating"
                         : "\(generationService.activeGenerationCount) chats generating")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Spacer()
                    Button(generationService.activeGenerationCount == 1 ? "Stop" : "Stop all") {
                        generationService.stopAll()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.xs)
            }

            Divider()
                .overlay(AppTheme.Colors.divider)

            // Status Footer
            statusFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Colors.sidebarBackground)
        .sheet(isPresented: $isCreatingProject) {
            ProjectEditorView(
                project: nil,
                dataStore: dataStore,
                onSave: { project in
                    dataStore.saveProject(project)
                    isCreatingProject = false
                    withAnimation(AppTheme.Animations.quick) {
                        selectedSelection = .project(project.id)
                        selectedConversationID = nil
                    }
                },
                onCancel: { isCreatingProject = false }
            )
        }
        .sheet(item: $editingProject) { project in
            ProjectEditorView(
                project: project,
                dataStore: dataStore,
                onSave: { updated in
                    dataStore.saveProject(updated)
                    editingProject = nil
                },
                onCancel: { editingProject = nil }
            )
        }
        .sheet(item: $mergeSource) { source in
            MergeTargetPicker(
                source: source,
                allConversations: dataStore.conversations,
                onPick: { target in
                    dataStore.mergeConversation(source, into: target)
                    if selectedConversationID == source.id {
                        selectedConversationID = target.id
                    }
                    mergeSource = nil
                },
                onCancel: { mergeSource = nil }
            )
        }
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
            //
            // Tab layout owns this control in the tab strip, where it stays put
            // whether the drawer is open or shut. Keeping a second copy in the
            // sidebar header would mean two buttons for one piece of state —
            // and the header's copy disappears with the sidebar it toggles.
            if layout != .tabbed {
                HoverIconButton(
                    systemName: "sidebar.left",
                    size: isCompact ? 18 : 16,
                    baseColor: isCompact ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textSecondary,
                    hoverColor: isCompact ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textPrimary,
                    helpText: isCompact ? "Expand Sidebar" : "Collapse Sidebar"
                ) {
                    isCompact.toggle()
                }
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
    
    // MARK: - Projects

    @ViewBuilder
    private var projectsSection: some View {
        if !dataStore.projects.isEmpty || !isCompact {
            VStack(spacing: AppTheme.Spacing.xs) {
                if !isCompact {
                    HStack {
                        Text("PROJECTS")
                            .font(AppTheme.Typography.captionSecondary)
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                            .tracking(1.2)
                        Spacer()
                        HoverIconButton(
                            systemName: "plus",
                            size: 11,
                            baseColor: AppTheme.Colors.textTertiary,
                            hoverColor: AppTheme.Colors.accentPrimary,
                            helpText: "New project"
                        ) {
                            isCreatingProject = true
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.top, AppTheme.Spacing.md)
                }

                ForEach(dataStore.projects) { project in
                    projectRow(project)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                }
            }
            .padding(.bottom, dataStore.projects.isEmpty ? 0 : AppTheme.Spacing.sm)

            if !dataStore.projects.isEmpty {
                Divider().overlay(AppTheme.Colors.divider)
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = selectedSelection == .project(project.id)
        return Button {
            withAnimation(AppTheme.Animations.spring) {
                selectedSelection = .project(project.id)
                selectedConversationID = nil
            }
        } label: {
            HStack(spacing: isCompact ? 0 : AppTheme.Spacing.md) {
                Text(project.emoji)
                    .font(.system(size: 14))
                    .frame(width: 28, height: 24)
                if !isCompact {
                    Text(project.name)
                        .font(AppTheme.Typography.callout)
                        .foregroundStyle(isSelected ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    let count = dataStore.conversationsForSelection(.project(project.id)).count
                    if count > 0 {
                        Text("\(count)")
                            .font(AppTheme.Typography.captionSecondary)
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                    }
                }
            }
            .padding(.horizontal, isCompact ? AppTheme.Spacing.xs : AppTheme.Spacing.md)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                    .fill(isSelected ? AppTheme.Colors.accentPrimary.opacity(0.12) : Color.clear)
            }
            .contentShape(Rectangle())
            .help(isCompact ? project.name : "")
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editingProject = project
            } label: {
                Label("Edit Project…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                if selectedSelection == .project(project.id) {
                    selectedSelection = .chat
                    selectedConversationID = nil
                }
                dataStore.deleteProject(project)
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
        }
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
                                // Escape exits the search field. `.onKeyPress`
                                // (macOS 14+) consumes the event so the system
                                // beep doesn't fire.
                                .onKeyPress(.escape) {
                                    exitSearch()
                                    return .handled
                                }
                        }

                        Button {
                            exitSearch()
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
                            VStack(alignment: .leading, spacing: 2) {
                                ConversationRow(
                                    conversation: conversation,
                                    isSelected: selectedConversationID == conversation.id,
                                    isCompact: isCompact,
                                    isGeneratingResponse: generationService.isStreaming(conversation.id),
                                    hasUnseenReply: generationService.hasUnseenReply(conversation.id)
                                ) {
                                    withAnimation(AppTheme.Animations.quick) {
                                        selectedConversationID = conversation.id
                                    }
                                }
                                if !isCompact, !searchQuery.isEmpty,
                                   let snippet = dataStore.searchSnippet(for: conversation, query: searchQuery) {
                                    SearchSnippetView(snippet: snippet, term: searchQuery)
                                        .padding(.leading, AppTheme.Spacing.lg)
                                        .padding(.trailing, AppTheme.Spacing.sm)
                                }
                            }
                            .id(conversation.id)
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

                                Button {
                                    mergeSource = conversation
                                } label: {
                                    Label("Merge into…", systemImage: "arrow.triangle.merge")
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
                    // Profile + settings grouped at the top of the vertical
                    // footer (the "bottom-left" cluster in compact form).
                    profileButton(size: 22)

                    settingsButton(size: 14)

                    helpButton(size: 14)

                    HoverIconButton(
                        systemName: isDarkMode ? "moon.fill" : "sun.max.fill",
                        size: 14,
                        baseColor: AppTheme.Colors.textTertiary,
                        hoverColor: AppTheme.Colors.textPrimary,
                        helpText: isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode"
                    ) {
                        isDarkMode.toggle()
                    }

                    StatusBadge(
                        backend: aiManager.currentBackend,
                        statusMessage: aiManager.statusMessage,
                        modelName: activeModelName,
                        isCompact: true
                    )
                }
                .padding(.vertical, AppTheme.Spacing.md)
            } else {
                HStack(spacing: AppTheme.Spacing.sm) {
                    // Left cluster: profile + settings + theme toggle.
                    profileButton(size: 20)

                    settingsButton(size: 12)

                    helpButton(size: 12)

                    HoverIconButton(
                        systemName: isDarkMode ? "moon.fill" : "sun.max.fill",
                        size: 12,
                        baseColor: AppTheme.Colors.textTertiary,
                        hoverColor: AppTheme.Colors.textPrimary,
                        helpText: isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode"
                    ) {
                        isDarkMode.toggle()
                    }

                    Spacer()

                    // Right cluster: model selector + connection status.
                    modelSelector

                    StatusBadge(
                        backend: aiManager.currentBackend,
                        statusMessage: aiManager.statusMessage,
                        modelName: activeModelName,
                        isCompact: false
                    )
                }
                .padding(AppTheme.Spacing.md)
            }
        }
    }
    
    /// The model name the active backend is currently using, if any — surfaced
    /// in the connection-status popover.
    private var activeModelName: String? {
        switch aiManager.currentBackend {
        case .ollama: return aiManager.selectedOllamaModel
        case .openAICompatible: return aiManager.selectedOpenAIModel
        case .appleFoundationModels, .none: return nil
        }
    }

    /// Inline model picker for the active backend. Hidden when the backend
    /// exposes no selectable models (e.g. Apple Foundation Models, or before
    /// a connection is established).
    @ViewBuilder
    private var modelSelector: some View {
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
        } else if aiManager.currentBackend == .openAICompatible && !aiManager.availableOpenAIModels.isEmpty {
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
    }

    /// Collapses the search bar back to the "RECENT" header. Used by both
    /// the X button and the Escape key while the search field is focused.
    private func exitSearch() {
        withAnimation(AppTheme.Animations.quick) {
            searchQuery = ""
            isSearching = false
        }
        isSearchFocused = false
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
        NSApp.activate()
        #endif
    }
    
    /// Small avatar pip in the status footer. Tapping it opens a popover with
    /// the active profile's identity, a shortcut into Profile settings, and
    /// Sign Out. Falls back to a generic icon when no profile is signed in
    /// (shouldn't happen here since we gate the whole app on sign-in, but
    /// keeps the view defensible).
    private func profileButton(size: CGFloat) -> some View {
        Button {
            showingProfileMenu.toggle()
        } label: {
            Group {
                if let profile = profileStore.currentProfile {
                    AvatarCircle(initials: profile.initials, size: size, imageData: profile.avatarImageData)
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: size * 0.9))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
            }
            .help(profileStore.currentProfile?.displayName ?? "Profile")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingProfileMenu, arrowEdge: .top) {
            profileMenu
        }
    }

    @ViewBuilder
    private var profileMenu: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if let profile = profileStore.currentProfile {
                HStack(spacing: AppTheme.Spacing.md) {
                    AvatarCircle(initials: profile.initials, size: 40, imageData: profile.avatarImageData)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        if !profile.email.isEmpty {
                            Text(profile.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(signInMethodLabel(profile.signInMethod))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                Button {
                    showingProfileMenu = false
                    // Deep-link to Profile tab: SettingsView reads this
                    // once on appear and clears it. See SettingsView.deepLinkTabKey.
                    UserDefaults.standard.set(SettingsView.SettingsTab.profile.rawValue,
                                              forKey: SettingsView.deepLinkTabKey)
                    openSettings()
                } label: {
                    Label("Manage Profile…", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    showingProfileMenu = false
                    profileStore.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(AppTheme.Colors.statusOffline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 260)
    }

    private func signInMethodLabel(_ method: SignInMethod) -> String {
        switch method {
        case .apple:  return "Signed in with Apple"
        case .google: return "Signed in with Google (local)"
        case .email:  return "Signed in with Email"
        case .guest:  return "Guest profile"
        }
    }

    // MARK: - Help

    private func helpButton(size: CGFloat) -> some View {
        Button {
            showingHelp.toggle()
        } label: {
            HoverIconLabel(systemName: "questionmark.circle", size: size, helpText: "Keyboard shortcuts & tips")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingHelp, arrowEdge: .top) {
            helpPopover
        }
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Shortcuts & Tips")
                .font(.headline)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                shortcutRow("⌘N", layout == .tabbed ? "New tab" : "New conversation")
                // Only advertise the tab bindings where they exist — in the
                // sidebar layout ⌘W still closes the window.
                if layout == .tabbed {
                    shortcutRow("⌘T", "Open conversation…")
                    shortcutRow("⌘W", "Close tab")
                    shortcutRow("⇧⌘T", "Reopen closed tab")
                }
                shortcutRow("⌘↩", "Send message")
                shortcutRow("↑ ↓", "Cycle previous prompts")
                shortcutRow("Esc", "Exit search")
                shortcutRow("⌘V", "Paste an image or text")
                // Only advertise the global hotkey when it's actually armed —
                // otherwise the row would lie. Shows the user's real binding.
                if globalShortcutEnabled {
                    shortcutRow(HotkeyManager.shared.currentShortcutDescription(), "Toggle floating bubble")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                tipRow("doc.badge.plus", "Drag & drop an image, PDF, or text file into the chat")
                tipRow("circle.fill", "Click the status dot for connection details")
                tipRow("slider.horizontal.3", "Set custom instructions per conversation from the chat header")
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 300, alignment: .leading)
    }

    private func shortcutRow(_ keys: String, _ label: String) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(keys)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(width: 60, alignment: .leading)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
        }
    }

    private func tipRow(_ icon: String, _ label: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Colors.accentPrimary)
                .frame(width: 18)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
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

struct MergeTargetPicker: View {
    let source: Conversation
    let allConversations: [Conversation]
    let onPick: (Conversation) -> Void
    let onCancel: () -> Void

    private var candidates: [Conversation] {
        allConversations
            .filter { $0.id != source.id && !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Merge Conversation")
                        .font(AppTheme.Typography.headline)
                    Text("Append messages from \"\(source.title)\" into another conversation. The source will be deleted.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            if candidates.isEmpty {
                Text("No other conversations to merge into.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(candidates) { target in
                            Button {
                                onPick(target)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.title)
                                            .font(AppTheme.Typography.body)
                                            .foregroundStyle(AppTheme.Colors.textPrimary)
                                        Text("\(target.messages.count) messages • \(target.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(AppTheme.Typography.captionSecondary)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(AppTheme.Spacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(AppTheme.Colors.backgroundSecondary.opacity(0.5))
                            )
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 480, height: 420)
    }
}

/// Renders a search snippet with the matched term highlighted.
struct SearchSnippetView: View {
    let snippet: String
    let term: String

    private var attributed: AttributedString {
        var attributed = AttributedString(snippet)
        attributed.foregroundColor = .secondary
        let lowerTerm = term.lowercased().split(separator: " ").first.map(String.init) ?? term.lowercased()
        let snippetLower = snippet.lowercased()
        guard let range = snippetLower.range(of: lowerTerm) else { return attributed }
        let lower = snippet.distance(from: snippet.startIndex, to: range.lowerBound)
        let length = snippet.distance(from: range.lowerBound, to: range.upperBound)
        let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: lower)
        let attrEnd = attributed.index(attrStart, offsetByCharacters: length)
        if attrEnd <= attributed.endIndex {
            attributed[attrStart..<attrEnd].foregroundColor = AppTheme.Colors.textPrimary
            attributed[attrStart..<attrEnd].font = AppTheme.Typography.captionSecondary.weight(.semibold)
            attributed[attrStart..<attrEnd].backgroundColor = AppTheme.Colors.accentPrimary.opacity(0.25)
        }
        return attributed
    }

    var body: some View {
        Text(attributed)
            .font(AppTheme.Typography.captionSecondary)
            .lineLimit(2)
            .padding(.bottom, 4)
    }
}
