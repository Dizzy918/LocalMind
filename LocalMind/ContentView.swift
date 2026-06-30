//
//  ContentView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    let aiManager: AIServiceManager
    let dataStore: DataStore
    let profileStore: ProfileStore

    @State private var selectedSelection: SidebarSelection = .chat
    @State private var selectedConversationID: UUID?
    
    // Sidebar state — persisted width is only read on launch and written on drag end
    @AppStorage("sidebarWidth") private var persistedSidebarWidth: Double = 260
    @State private var liveSidebarWidth: Double = 260
    @State private var dragStartWidth: Double? = nil
    
    // Resizer UX state
    @State private var isHoveringResizer = false
    @GestureState private var isDraggingResizer = false
    @State private var hoverTask: Task<Void, Never>?
    
    private var isSidebarCompact: Binding<Bool> {
        Binding(
            get: { liveSidebarWidth < 140 },
            set: { compact in
                withAnimation(AppTheme.Animations.spring) {
                    liveSidebarWidth = compact ? 70 : 260
                }
                persistedSidebarWidth = liveSidebarWidth
            }
        )
    }
    
    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                selectedSelection: $selectedSelection,
                selectedConversationID: $selectedConversationID,
                isCompact: isSidebarCompact,
                dataStore: dataStore,
                aiManager: aiManager,
                profileStore: profileStore,
                onNewConversation: startNewConversation
            )
            .frame(width: CGFloat(liveSidebarWidth))
            
            // Resizer handle
            Rectangle()
                .fill(isHoveringResizer || isDraggingResizer ? AppTheme.Colors.accentPrimary : AppTheme.Colors.divider)
                .frame(width: isHoveringResizer || isDraggingResizer ? 3 : 1)
                .padding(.horizontal, isHoveringResizer || isDraggingResizer ? 4.5 : 5.5)
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoverTask?.cancel()
                    
                    if hovering {
                        // Delay both visual highlight and cursor to avoid annoying flashes when just passing over
                        hoverTask = Task {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            if !Task.isCancelled {
                                await MainActor.run {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        isHoveringResizer = true
                                    }
                                    #if os(macOS)
                                    NSCursor.resizeLeftRight.push()
                                    #endif
                                }
                            }
                        }
                    } else {
                        // If it was fully hovered, we need to pop the cursor.
                        // We check if it was actually hovered (isHoveringResizer is true)
                        // to ensure we don't pop a cursor we never pushed.
                        let wasHovering = isHoveringResizer
                        
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHoveringResizer = false
                        }
                        
                        if wasHovering {
                            #if os(macOS)
                            DispatchQueue.main.async { NSCursor.pop() }
                            #endif
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .updating($isDraggingResizer) { _, state, _ in
                            state = true
                        }
                        .onChanged { value in
                            if dragStartWidth == nil { dragStartWidth = liveSidebarWidth }
                            let proposed = dragStartWidth! + Double(value.translation.width)
                            liveSidebarWidth = max(70, min(proposed, 400))
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                            
                            // Only snap to the absolute minimum if they drop it very close to the edge
                            if liveSidebarWidth < 100 {
                                withAnimation(AppTheme.Animations.spring) {
                                    liveSidebarWidth = 70
                                }
                            }
                            
                            // Persist only on drag end — avoids UserDefaults thrashing
                            persistedSidebarWidth = liveSidebarWidth
                        }
                )
            
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            liveSidebarWidth = persistedSidebarWidth
            setAppIcon()
        }
        .task {
            await aiManager.detectAndConnect()
        }
    }
    
    @State private var draftConversation: Conversation?

    @ViewBuilder
    private var detailView: some View {
        if let id = selectedConversationID {
            // A SINGLE ChatView branch, keyed by the conversation id. This is
            // deliberate: when the first message of a brand-new chat lands, the
            // conversation moves from `draftConversation` (in-memory) into
            // `dataStore`. If we branched the view on "is it in dataStore yet?",
            // SwiftUI would swap _ConditionalContent cases and tear down /
            // recreate ChatView — killing the in-flight streaming Task and its
            // `isStreaming` state, so the typing indicator never shows on the
            // first reply. One stable branch keeps the view (and its stream)
            // alive across that draft→persisted transition.
            ChatView(
                aiManager: aiManager,
                dataStore: dataStore,
                conversation: bindingForConversation(id)
            )
            .id(id)
        } else {
            // No selection — auto-start a draft so the chat input is never
            // wired to a `.constant` binding (which would silently drop
            // sendMessage's writes and lose the user's first message).
            // Defer the state mutation to the next runloop tick so SwiftUI
            // doesn't trip the "Modifying state during view update" trap
            // if onAppear happens to fire during the same frame as the
            // parent's render.
            Color.clear
                .onAppear {
                    DispatchQueue.main.async { startNewConversation() }
                }
        }
    }

    /// Builds the conversation binding for `id`, reading from dataStore first
    /// and falling back to the in-memory draft. The setter keeps the draft in
    /// sync (so writes within a single sendMessage call always see the latest
    /// state) and persists to dataStore once the conversation has any messages
    /// — which is also what keeps empty drafts out of the sidebar.
    private func bindingForConversation(_ id: UUID) -> Binding<Conversation> {
        Binding(
            get: {
                if let stored = dataStore.conversations.first(where: { $0.id == id }) {
                    return stored
                }
                if let draft = draftConversation, draft.id == id {
                    return draft
                }
                return Conversation()
            },
            set: { updated in
                if draftConversation?.id == updated.id {
                    draftConversation = updated
                }
                if !updated.messages.isEmpty
                    || dataStore.conversations.contains(where: { $0.id == updated.id }) {
                    dataStore.saveConversation(updated)
                }
            }
        )
    }

    /// Creates a draft conversation in @State and selects it. The draft is
    /// persisted to dataStore by the binding setter the moment the user sends
    /// the first message, so empty drafts never pollute the sidebar.
    private func startNewConversation() {
        let newConversation: Conversation
        switch selectedSelection {
        case .chat:
            newConversation = Conversation(toolType: .chat)
        case .customTool(let id):
            newConversation = Conversation(toolType: .chat, customToolID: id)
        }
        draftConversation = newConversation
        selectedConversationID = newConversation.id
    }
    
    private func setAppIcon() {
        #if os(macOS)
        let config = NSImage.SymbolConfiguration(pointSize: 128, weight: .regular)
        if let image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            NSApplication.shared.applicationIconImage = image
        }
        #endif
    }
}
