//
//  ChatTabBar.swift
//  LocalMind
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One open conversation, flattened for the tab strip. Kept separate from
/// `Conversation` so the strip re-renders only when something it actually
/// draws changes, not on every streamed token.
struct ChatTab: Identifiable, Equatable {
    let id: UUID
    let title: String
    let emoji: String
    let isStreaming: Bool
    let hasUnseenReply: Bool
}

/// Safari-style tab strip. It sits *inside* the window's title bar (see
/// `WindowChrome`), so it reserves room for the traffic lights on the leading
/// edge and leaves the trailing end draggable.
struct ChatTabBar: View {
    let tabs: [ChatTab]
    let activeID: UUID?
    @Binding var isSidebarVisible: Bool
    /// Recent conversations for the history menu, newest first.
    let history: [Conversation]
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNewTab: () -> Void
    /// Opens the searchable picker (same surface as ⌘T).
    let onBrowseAll: () -> Void

    /// Ties the active tab's background across tabs so it slides between them
    /// instead of cutting, the way AppKit's segmented controls do.
    @Namespace private var tabHighlight

    // No traffic-light inset here on purpose.
    //
    // The strip was originally indented ~72pt to clear the window buttons, on
    // the assumption it would sit *inside* the title bar. It doesn't:
    // `.fullSizeContentView` is set, but SwiftUI insets its content below the
    // title bar anyway, so the strip renders as its own row with the buttons on
    // the row above. Reserving space for buttons that aren't on this row just
    // pushed the sidebar icon and first tab needlessly right.
    //
    // If the strip is ever genuinely merged into the title bar (see the note on
    // WindowChrome), the inset has to come back.
    private let minTabWidth: CGFloat = 110
    private let maxTabWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            HoverIconButton(
                systemName: "sidebar.left",
                size: 14,
                baseColor: isSidebarVisible ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textTertiary,
                hoverColor: AppTheme.Colors.textPrimary,
                helpText: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            ) {
                withAnimation(AppTheme.Animations.spring) {
                    isSidebarVisible.toggle()
                }
            }

            GeometryReader { geo in
                let width = tabWidth(available: geo.size.width)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(tabs) { tab in
                                ChatTabItem(
                                    tab: tab,
                                    isActive: tab.id == activeID,
                                    namespace: tabHighlight,
                                    onSelect: { onSelect(tab.id) },
                                    onClose: { onClose(tab.id) }
                                )
                                .frame(width: width)
                                .id(tab.id)
                                // Safari's feel on open/close: the tab grows out
                                // of its leading edge while its neighbours make
                                // room, rather than blinking into place.
                                .transition(
                                    .scale(scale: 0.8, anchor: .leading)
                                    .combined(with: .opacity)
                                )
                            }
                        }
                        // Drives both the insert/remove transitions above and
                        // the width reflow of the surviving tabs.
                        .animation(AppTheme.Animations.tab, value: tabs)
                    }
                    // Only let the strip scroll once the tabs actually overflow,
                    // otherwise a short strip rubber-bands under the trackpad.
                    .scrollDisabled(CGFloat(tabs.count) * width <= geo.size.width)
                    .onChange(of: activeID) { _, id in
                        guard let id else { return }
                        withAnimation(AppTheme.Animations.quick) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .frame(height: 30)

            historyMenu

            HoverIconButton(
                systemName: "plus",
                size: 13,
                baseColor: AppTheme.Colors.textTertiary,
                hoverColor: AppTheme.Colors.accentPrimary,
                helpText: "New conversation (⌘N)",
                action: onNewTab
            )
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: 42)
        .background {
            ZStack {
                AppTheme.Colors.backgroundSecondary
                // Sits behind the tabs and buttons, so they still get their
                // clicks while empty strip space drags the window. This is what
                // replaces the hidden title bar's grab area.
                WindowDragArea()
            }
        }
    }

    /// Recent conversations, one click away without a permanent column. Capped
    /// at a menu's worth — "Search All…" is the escape hatch into the picker.
    private var historyMenu: some View {
        Menu {
            if history.isEmpty {
                Text("No conversations yet")
            } else {
                ForEach(history.prefix(12)) { conversation in
                    Button {
                        onSelect(conversation.id)
                    } label: {
                        Text("\(conversation.displayEmoji)  \(conversation.title)")
                    }
                }
            }

            Divider()

            // No .keyboardShortcut here — the File menu owns ⌘T, and a second
            // binding for the same action just makes the match ambiguous.
            Button("Search All…", action: onBrowseAll)
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.Colors.textTertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help("Recent conversations")
    }

    /// Safari's sizing rule: tabs share the strip evenly, growing to a cap and
    /// shrinking to a floor before the strip starts scrolling.
    private func tabWidth(available: CGFloat) -> CGFloat {
        guard !tabs.isEmpty, available > 0 else { return minTabWidth }
        let even = available / CGFloat(tabs.count)
        return min(maxTabWidth, max(minTabWidth, even))
    }
}

/// A single tab. Close button appears on hover (or while active) so the strip
/// stays quiet when the pointer is elsewhere.
private struct ChatTabItem: View {
    let tab: ChatTab
    let isActive: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            leadingGlyph
                .frame(width: 16)

            Text(tab.title)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(isActive ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Reserve the close button's slot at all times so the title doesn't
            // reflow — and jump under the pointer — the moment you hover.
            Group {
                if isHovered || isActive {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .padding(3)
                            .background {
                                Circle().fill(isHovered ? AppTheme.Colors.hover : Color.clear)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab (⌘W)")
                }
            }
            .frame(width: 14)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                // Hover tint sits underneath and belongs to this tab alone.
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                    .fill(!isActive && isHovered ? AppTheme.Colors.hover : Color.clear)

                // The active chip is a single shared view handed between tabs
                // via matchedGeometryEffect, so selecting a neighbour slides it
                // across rather than popping it out here and in over there.
                if isActive {
                    RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                        .fill(AppTheme.Colors.backgroundPrimary)
                        .overlay {
                            RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                                .strokeBorder(AppTheme.Colors.border, lineWidth: 1)
                        }
                        .matchedGeometryEffect(id: "activeTabChip", in: namespace)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .animation(AppTheme.Animations.tabHighlight, value: isActive)
        .help(tab.title)
        .onHover { hovering in
            withAnimation(AppTheme.Animations.quick) { isHovered = hovering }
        }
    }

    /// Mirrors the sidebar row's vocabulary: a live pulse while streaming, a
    /// dot for a reply you haven't seen, otherwise the conversation's emoji.
    @ViewBuilder
    private var leadingGlyph: some View {
        if tab.isStreaming {
            PulsingDot(size: 6)
        } else if tab.hasUnseenReply {
            Circle()
                .fill(AppTheme.Colors.accentPrimary)
                .frame(width: 6, height: 6)
        } else {
            Text(tab.emoji)
                .font(.system(size: 12))
        }
    }
}

// MARK: - Window Drag Area

/// A transparent patch that drags the window when you press on it.
///
/// `NSWindow.isMovableByWindowBackground` is the usual one-liner for this, but
/// it doesn't work under SwiftUI — the hosting view handles the mouse-down, so
/// the window never sees it. Verified: with only that flag set, dragging the
/// tab strip did nothing. `mouseDownCanMoveWindow` is the per-view opt-in
/// AppKit actually consults, and it has the added benefit of confining the drag
/// region to the strip instead of making the whole window background draggable.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Window Chrome

/// Pushes the window's content up into the title bar so the tab strip can live
/// there, and puts it back when the user returns to the sidebar layout.
///
/// Applied once at the top of `ContentView` (rather than only inside the tabbed
/// branch) so switching back to classic still runs the restore path — a
/// configurator that disappears with its branch never gets the chance.
struct WindowChrome: NSViewRepresentable {
    let mergesTitleBar: Bool

    /// Applies on `viewDidMoveToWindow` rather than a dispatched block.
    ///
    /// The previous version hopped to the next runloop tick and bailed if
    /// `view.window` was still nil — which is exactly what happens on launch.
    /// It never retried, so `.fullSizeContentView` was silently never set: the
    /// title bar stayed a separate strip above the tab bar instead of the tabs
    /// living inside it. This hook fires precisely when the window attaches.
    final class ChromeView: NSView {
        var mergesTitleBar = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyChrome()
        }

        func applyChrome() {
            guard let window else { return }

            // Opt into AppKit's document-window open/close animation.
            // Minimising is untouched — the genie is a WindowServer effect the
            // system already applies to the yellow button, not something an app
            // can drive.
            window.animationBehavior = .documentWindow

            if mergesTitleBar {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            } else {
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarAppearsTransparent = false
                window.titleVisibility = .visible
            }
            // Dragging is handled by WindowDragArea in the tab strip, not by
            // this flag — under SwiftUI it doesn't fire, and it would also make
            // empty chat background drag the window, which isn't wanted.
            window.isMovableByWindowBackground = false
        }
    }

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.mergesTitleBar = mergesTitleBar
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.mergesTitleBar = mergesTitleBar
        nsView.applyChrome()
    }
}
