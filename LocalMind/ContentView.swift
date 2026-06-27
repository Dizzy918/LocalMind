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
        if let id = selectedConversationID,
           dataStore.conversations.contains(where: { $0.id == id }) {
            ChatView(
                aiManager: aiManager,
                dataStore: dataStore,
                conversation: Binding(
                    get: { dataStore.conversations.first(where: { $0.id == id }) ?? Conversation() },
                    set: { dataStore.saveConversation($0) }
                )
            )
            .id(id)
        } else if let draft = draftConversation, draft.id == selectedConversationID {
            // Empty draft — held in @State so it doesn't pollute the sidebar.
            // The setter persists the moment the conversation gains any messages.
            ChatView(
                aiManager: aiManager,
                dataStore: dataStore,
                conversation: Binding(
                    get: { draftConversation ?? draft },
                    set: { updated in
                        if updated.messages.isEmpty {
                            draftConversation = updated
                        } else {
                            dataStore.saveConversation(updated)
                            draftConversation = nil
                        }
                    }
                )
            )
            .id(draft.id)
        } else {
            let initialConversation: Conversation = {
                switch selectedSelection {
                case .chat:
                    return Conversation(toolType: .chat)
                case .customTool(let id):
                    return Conversation(toolType: .chat, customToolID: id)
                }
            }()

            ChatView(
                aiManager: aiManager,
                dataStore: dataStore,
                conversation: .constant(initialConversation)
            )
            .onAppear {
                draftConversation = initialConversation
                selectedConversationID = initialConversation.id
            }
        }
    }
    
    /// Creates the conversation in-memory only. It's persisted by the binding
    /// setter on ChatView the moment the first message lands, so the sidebar
    /// stays clean of empty drafts until the user actually engages.
    private func startNewConversation() {
        let newConversation: Conversation
        switch selectedSelection {
        case .chat:
            newConversation = Conversation(toolType: .chat)
        case .customTool(let id):
            newConversation = Conversation(toolType: .chat, customToolID: id)
        }
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
