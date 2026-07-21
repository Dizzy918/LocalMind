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
    let generationService: ChatGenerationService

    @State private var selectedSelection: SidebarSelection = .chat
    @State private var selectedConversationID: UUID?
    /// Unsent conversations, keyed by id — they have nothing on disk yet, so
    /// the tab strip and the chat binding both resolve them from here.
    ///
    /// This is a dictionary, not a single optional, because the tab layout can
    /// have several unsent drafts open at once. With one slot, opening a second
    /// new tab replaced the first: its id stayed in `openTabIDs` but resolved to
    /// nothing, so that tab vanished from the strip while remaining stuck in the
    /// list — unselectable and uncloseable.
    @State private var draftConversations: [UUID: Conversation] = [:]

    // First-run onboarding: shown once, then never again.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false

    // Which shell we're wearing. Stored as a String because @AppStorage can't
    // hold a bare enum; `layout` is the typed view onto it.
    @AppStorage(AppLayout.storageKey) private var layoutRaw: String = AppLayout.classic.rawValue
    private var layout: AppLayout { AppLayout(rawValue: layoutRaw) ?? .classic }

    // MARK: Tab-layout state

    /// Conversations the user has open, in strip order. Only meaningful in the
    /// tabbed layout — `selectedConversationID` stays the single source of
    /// truth for what's on screen in both layouts, and this list follows it.
    @State private var openTabIDs: [UUID] = []
    /// Tabs closed this session, oldest first. ⇧⌘T pops from the end.
    @State private var recentlyClosedIDs: [UUID] = []
    /// In the tabbed layout the sidebar is a drawer, hidden until asked for.
    @AppStorage("tabbedSidebarVisible") private var isTabbedSidebarVisible = false
    /// ⌘T / ＋ / "Search All…" all raise the same picker.
    @State private var showingTabPicker = false

    /// Open tabs survive relaunch, the way Safari reopens your windows.
    private static let persistedTabsKey = "openTabIDs"
    private static let persistedActiveTabKey = "activeTabID"

    // MARK: Sidebar sizing

    // Persisted width is only read on launch and written on drag end
    @AppStorage("sidebarWidth") private var persistedSidebarWidth: Double = 260
    @State private var liveSidebarWidth: Double = 260
    @State private var dragStartWidth: Double? = nil

    /// Upper bound for the draggable sidebar width. Kept modest so dragging
    /// can't swallow the window — the chat column always keeps the majority of
    /// the space. (The compact minimum is 70.)
    private let maxSidebarWidth: Double = 320

    /// Narrowest the tabbed layout's sidebar drawer may get. Unlike the classic
    /// sidebar it never collapses to an icon rail, so it can't go below the
    /// width its full-size content needs.
    private let tabbedSidebarMinWidth: Double = 200

    /// Total width of the drag handle (line + its padding), which stays 12pt in
    /// both its resting and hovered states. The drawer animation needs it as a
    /// constant so the slide doesn't jitter when the handle highlights.
    private let resizerWidth: CGFloat = 12

    private var tabbedSidebarTargetWidth: CGFloat {
        CGFloat(max(liveSidebarWidth, tabbedSidebarMinWidth))
    }

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

    /// In the tabbed layout the sidebar has no compact (icon-rail) form — it's
    /// either open as a drawer or gone. The tab strip's button is the only
    /// control for that, so the sidebar header hides its own copy and this
    /// binding just reports "never compact".
    ///
    /// The setter is kept as a safety net: anything inside SidebarView that
    /// still writes to `isCompact` closes the drawer rather than silently
    /// squeezing the sidebar to a 70pt rail it has no layout for.
    private var tabbedSidebarCompact: Binding<Bool> {
        Binding(
            get: { false },
            set: { _ in
                withAnimation(AppTheme.Animations.drawer) {
                    isTabbedSidebarVisible = false
                }
            }
        )
    }

    var body: some View {
        Group {
            switch layout {
            case .classic: classicLayout
            case .tabbed:  tabbedLayout
            }
        }
        // NOTE: do not put .animation(_:value:) on this Group. Animating the
        // whole shell on selectedConversationID puts the tab strip inside an
        // animated ancestor that competes with its own
        // .animation(tab, value: tabs), and SwiftUI defers the strip's
        // invalidation — it renders one interaction behind, so closing a tab
        // appears to do nothing until the next click. The pane crossfade is
        // scoped to detailView instead.
        .background(WindowChrome(mergesTitleBar: layout == .tabbed))
        .onAppear {
            // Clamp any previously-persisted width to the current cap, so a
            // value saved before the cap existed can't reopen the sidebar wide.
            liveSidebarWidth = min(persistedSidebarWidth, maxSidebarWidth)
            setAppIcon()
            // Bring back last session's tabs before seeding, so a restored
            // strip isn't clobbered by a fresh draft.
            restoreOpenTabs()
            select(selectedConversationID)
            if !hasCompletedOnboarding {
                if dataStore.conversations.isEmpty {
                    showingOnboarding = true
                } else {
                    // Upgrading users with existing history aren't new — don't
                    // greet them with a first-run wizard.
                    hasCompletedOnboarding = true
                }
            }
        }
        .task {
            await aiManager.detectAndConnect()
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(aiManager: aiManager) {
                hasCompletedOnboarding = true
                showingOnboarding = false
            }
            // First-run setup shouldn't be dismissible by accident — the
            // explicit "Start Chatting" / "Skip" buttons are the exits.
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingTabPicker) {
            TabPickerView(
                conversations: dataStore.conversationsForActiveProfile(),
                openTabIDs: Set(openTabIDs),
                onPick: { id in
                    showingTabPicker = false
                    select(id)
                },
                onNewChat: {
                    showingTabPicker = false
                    startNewConversation()
                },
                onCancel: { showingTabPicker = false }
            )
        }
        .onChange(of: profileStore.currentProfileID) { _, _ in
            // Switching profiles must not leave another profile's conversation
            // (or a half-typed draft) on screen. Clear the selection so the
            // detail pane falls back to a fresh draft for the new profile —
            // and drop the tab strip, which is full of the old profile's chats.
            draftConversations.removeAll()
            selectedConversationID = nil
            openTabIDs = []
            recentlyClosedIDs = []
        }
        .onChange(of: selectedConversationID) { _, _ in
            // Persisting only writes to UserDefaults — no view state is touched,
            // so it's safe to do reactively. Opening the tab is NOT: see `select`.
            persistOpenTabs()
        }
        .onChange(of: openTabIDs) { _, _ in
            persistOpenTabs()
        }
        .onChange(of: dataStore.conversations.count) { _, _ in
            pruneDeletedTabs()
        }
        .onChange(of: layoutRaw) { _, _ in
            // Switching into the tabbed layout mid-session: the current chat
            // becomes the first tab, so the strip is never empty.
            select(selectedConversationID)
        }
        // Menu commands reach us through NotificationCenter, which delivers
        // synchronously on the poster's run-loop turn — mid-menu-dispatch, not
        // during a normal event cycle. Mutating view state there gets deferred:
        // ⌘W would close a tab but the strip wouldn't repaint until the next
        // click. Hopping to the next main-queue tick puts the mutation in a
        // clean turn so it renders immediately.
        .onReceive(NotificationCenter.default.publisher(for: .newConversation)) { _ in
            DispatchQueue.main.async { startNewConversation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConversation)) { note in
            // The Agent Team panel saves a run as a conversation and asks us
            // to show it so the user can keep talking to that agent.
            guard let id = note.object as? UUID else { return }
            DispatchQueue.main.async {
                selectedSelection = .chat
                select(id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeCurrentTab)) { _ in
            DispatchQueue.main.async {
                if let id = selectedConversationID { closeTab(id) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reopenClosedTab)) { _ in
            DispatchQueue.main.async { reopenLastClosedTab() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTabPicker)) { _ in
            guard layout == .tabbed else { return }
            DispatchQueue.main.async { showingTabPicker = true }
        }
    }

    // MARK: - Layouts

    private var classicLayout: some View {
        HStack(spacing: 0) {
            sidebar(isCompact: isSidebarCompact)
                .frame(width: CGFloat(liveSidebarWidth))

            resizer

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var tabbedLayout: some View {
        VStack(spacing: 0) {
            ChatTabBar(
                tabs: openTabs,
                activeID: selectedConversationID,
                isSidebarVisible: $isTabbedSidebarVisible,
                history: dataStore.conversationsForActiveProfile(),
                onSelect: { select($0) },
                onClose: closeTab,
                onNewTab: startNewConversation,
                onBrowseAll: { showingTabPicker = true }
            )

            Divider()
                .overlay(AppTheme.Colors.divider)

            HStack(spacing: 0) {
                // The drawer slides rather than being inserted into the stack.
                // Keeping it mounted at its natural width and animating only
                // the *outer* frame is what makes this read like Finder's
                // sidebar: the content slides in from the left edge (hence
                // .trailing alignment) instead of squashing from zero width
                // while its labels reflow.
                HStack(spacing: 0) {
                    sidebar(isCompact: tabbedSidebarCompact)
                        .frame(width: tabbedSidebarTargetWidth)
                    resizer
                }
                .frame(
                    width: isTabbedSidebarVisible ? tabbedSidebarTargetWidth + resizerWidth : 0,
                    alignment: .trailing
                )
                .clipped()

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Scoped here, not on the shell — see the note in `body`.
                    .animation(AppTheme.Animations.paneSwap, value: selectedConversationID)
            }
            .animation(AppTheme.Animations.drawer, value: isTabbedSidebarVisible)
        }
    }

    private func sidebar(isCompact: Binding<Bool>) -> some View {
        SidebarView(
            selectedSelection: $selectedSelection,
            selectedConversationID: conversationSelection,
            isCompact: isCompact,
            dataStore: dataStore,
            aiManager: aiManager,
            profileStore: profileStore,
            generationService: generationService,
            onNewConversation: startNewConversation
        )
    }

    /// The draggable divider between sidebar and chat. Shared by both layouts.
    private var resizer: some View {
        Rectangle()
            .fill(isHoveringResizer || isDraggingResizer ? AppTheme.Colors.accentPrimary : AppTheme.Colors.divider)
            .frame(width: isHoveringResizer || isDraggingResizer ? 3 : 1)
            .padding(.horizontal, isHoveringResizer || isDraggingResizer ? 4.5 : 5.5)
            .contentShape(Rectangle())
            // Declarative resize cursor — macOS shows/hides it as the
            // pointer enters/leaves the handle, with no manual push/pop
            // stack to leak if a hover-out event is ever dropped (e.g. the
            // window closing mid-hover).
            .pointerStyle(.columnResize)
            .onHover { hovering in
                // onHover now only drives the visual highlight, with a small
                // delay so brushing past the 1px handle doesn't flicker it.
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHoveringResizer = true
                        }
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHoveringResizer = false
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
                        // The drawer has no compact form to snap into, so it
                        // stops at a readable width instead of the 70pt rail.
                        let floor: Double = layout == .tabbed ? tabbedSidebarMinWidth : 70
                        liveSidebarWidth = max(floor, min(proposed, maxSidebarWidth))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil

                        // Only snap to the absolute minimum if they drop it very close to the edge
                        if layout == .classic, liveSidebarWidth < 100 {
                            withAnimation(AppTheme.Animations.spring) {
                                liveSidebarWidth = 70
                            }
                        }

                        // Persist only on drag end — avoids UserDefaults thrashing
                        persistedSidebarWidth = liveSidebarWidth
                    }
            )
    }

    @ViewBuilder
    private var detailView: some View {
        if let id = selectedConversationID {
            // A SINGLE ChatView branch, keyed by the conversation id. This is
            // deliberate: when the first message of a brand-new chat lands, the
            // conversation moves from `draftConversations` (in-memory) into
            // `dataStore`. If we branched the view on "is it in dataStore yet?",
            // SwiftUI would swap _ConditionalContent cases and tear down /
            // recreate ChatView — killing the in-flight streaming Task and its
            // `isStreaming` state, so the typing indicator never shows on the
            // first reply. One stable branch keeps the view (and its stream)
            // alive across that draft→persisted transition.
            //
            // Only the active tab is rendered. Keeping every open tab alive in
            // a ZStack would mark them all as "appeared", and ChatView clears
            // its unseen-reply badge on appear — every background tab would
            // silently mark itself read.
            ChatView(
                aiManager: aiManager,
                dataStore: dataStore,
                generationService: generationService,
                conversation: bindingForConversation(id)
            )
            .id(id)
            // Switching tabs swaps the whole pane. A plain crossfade — not a
            // slide — because the panes have no spatial relationship to each
            // other, and sliding would imply one.
            .transition(.opacity)
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

    // MARK: - Tabs

    /// The open conversations, resolved for the strip. Drafts aren't in the
    /// data store yet, so they're resolved from `draftConversations`; ids that
    /// resolve to neither are dropped (the conversation was deleted).
    private var openTabs: [ChatTab] {
        openTabIDs.compactMap { id in
            if let stored = dataStore.conversations.first(where: { $0.id == id }) {
                // A freshly-saved conversation keeps its placeholder title until
                // the model names it — show the same "New Chat" the tab was
                // opened with rather than flashing "New Conversation".
                let isUnnamed = stored.title == "New Conversation"
                return ChatTab(
                    id: id,
                    title: isUnnamed ? "New Chat" : stored.title,
                    emoji: stored.displayEmoji,
                    isStreaming: generationService.isStreaming(id),
                    hasUnseenReply: generationService.hasUnseenReply(id)
                )
            }
            if let draft = draftConversations[id] {
                return ChatTab(
                    id: id,
                    title: "New Chat",
                    emoji: draft.displayEmoji,
                    isStreaming: false,
                    hasUnseenReply: false
                )
            }
            return nil
        }
    }

    /// The one way to change which conversation is on screen.
    ///
    /// Opening the tab and moving the selection MUST happen in a single call.
    /// They used to be split — selection here, tab opened later from
    /// `.onChange(of: selectedConversationID)` — which mutated `openTabIDs`
    /// during the processing of another state change. SwiftUI deferred that
    /// second mutation, so the strip rendered one interaction behind: clicking
    /// a chat showed nothing until the *next* click, and closing a tab looked
    /// like a no-op. Both writes in one transaction means one coherent render.
    private func select(_ id: UUID?) {
        if layout == .tabbed, let id, !openTabIDs.contains(id) {
            openTabIDs.append(id)
        }
        selectedConversationID = id
    }

    /// Selection binding handed to the sidebar, so its writes go through
    /// `select` rather than setting `selectedConversationID` behind our back.
    private var conversationSelection: Binding<UUID?> {
        Binding(
            get: { selectedConversationID },
            set: { select($0) }
        )
    }

    /// Closes a tab without touching the conversation — it stays in history and
    /// can be reopened from the sidebar or with ⇧⌘T.
    private func closeTab(_ id: UUID) {
        guard let index = openTabIDs.firstIndex(of: id) else { return }
        openTabIDs.remove(at: index)

        // Only saved conversations are worth remembering; an empty draft has
        // nothing to reopen.
        if dataStore.conversations.contains(where: { $0.id == id }) {
            recentlyClosedIDs.append(id)
            if recentlyClosedIDs.count > 20 { recentlyClosedIDs.removeFirst() }
        }
        draftConversations.removeValue(forKey: id)

        guard selectedConversationID == id else { return }
        if openTabIDs.isEmpty {
            // Closing the last tab leaves a blank window with no way back in,
            // so hand the user a fresh draft instead.
            startNewConversation()
        } else {
            // Fall to the tab that slid into this slot, or the new last one.
            selectedConversationID = openTabIDs[min(index, openTabIDs.count - 1)]
        }
    }

    /// ⇧⌘T. Skips ids whose conversation has since been deleted.
    private func reopenLastClosedTab() {
        guard layout == .tabbed else { return }
        while let id = recentlyClosedIDs.popLast() {
            guard dataStore.conversations.contains(where: { $0.id == id }) else { continue }
            selectedConversationID = id
            return
        }
    }

    /// Writes the strip to disk so the next launch can rebuild it.
    ///
    /// Drafts are skipped: an unsent conversation has nothing saved to restore
    /// from, so persisting its id would resurrect a tab pointing at nothing.
    private func persistOpenTabs() {
        guard layout == .tabbed else { return }
        let saved = openTabIDs.filter { id in
            dataStore.conversations.contains { $0.id == id }
        }
        UserDefaults.standard.set(saved.map(\.uuidString), forKey: Self.persistedTabsKey)

        let active = selectedConversationID.flatMap { id in
            saved.contains(id) ? id.uuidString : nil
        }
        UserDefaults.standard.set(active, forKey: Self.persistedActiveTabKey)
    }

    /// Rebuilds last session's strip. Ids are filtered against what the *active
    /// profile* can see, so a profile switch between launches can't reopen
    /// someone else's chats.
    private func restoreOpenTabs() {
        guard layout == .tabbed, openTabIDs.isEmpty else { return }

        let visible = Set(dataStore.conversationsForActiveProfile(includeArchived: true).map(\.id))
        let stored = (UserDefaults.standard.array(forKey: Self.persistedTabsKey) as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
            .filter { visible.contains($0) }
        guard !stored.isEmpty else { return }

        openTabIDs = stored

        let storedActive = UserDefaults.standard.string(forKey: Self.persistedActiveTabKey)
            .flatMap(UUID.init(uuidString:))
        selectedConversationID = stored.contains(where: { $0 == storedActive }) ? storedActive : stored.first
    }

    /// Drops tabs whose conversation was deleted (from the sidebar's context
    /// menu, or by clearing history), and re-anchors the selection if the
    /// deleted chat was the visible one.
    private func pruneDeletedTabs() {
        guard layout == .tabbed else { return }
        let live = Set(dataStore.conversations.map(\.id))
        let survivors = openTabIDs.filter { live.contains($0) || draftConversations[$0] != nil }
        guard survivors.count != openTabIDs.count else { return }

        openTabIDs = survivors
        recentlyClosedIDs.removeAll { !live.contains($0) }

        guard let selected = selectedConversationID, !survivors.contains(selected) else { return }
        if let fallback = survivors.last {
            selectedConversationID = fallback
        } else {
            startNewConversation()
        }
    }

    // MARK: - Conversations

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
                if let draft = draftConversations[id] {
                    return draft
                }
                return Conversation()
            },
            set: { updated in
                if draftConversations[updated.id] != nil {
                    draftConversations[updated.id] = updated
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
    ///
    /// In the tabbed layout this is also "new tab" — the selection change opens
    /// one via `select`.
    private func startNewConversation() {
        let newConversation: Conversation
        switch selectedSelection {
        case .chat:
            newConversation = Conversation(toolType: .chat)
        case .customTool(let id):
            newConversation = Conversation(toolType: .chat, customToolID: id)
        case .project(let id):
            // Born into the project — it inherits the project's agent,
            // collections, and context at generation time.
            newConversation = Conversation(toolType: .chat, projectID: id)
        }
        // Draft first: `select` opens the tab, and `openTabs` can only resolve
        // the new id once `draftConversations` holds it.
        draftConversations[newConversation.id] = newConversation
        select(newConversation.id)
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
