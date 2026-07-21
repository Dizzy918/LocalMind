//
//  TabPickerView.swift
//  LocalMind
//

import SwiftUI

/// Safari's new-tab page, adapted: a searchable list of past conversations to
/// reopen as tabs, with "start a fresh chat" as the first move.
///
/// Reached with ⌘T or the tab strip's ＋. The tab strip's history menu covers
/// the same ground for mouse users; this one is built for typing.
struct TabPickerView: View {
    let conversations: [Conversation]
    /// Ids already open, so the picker can say so instead of pretending a
    /// second tab will appear.
    let openTabIDs: Set<UUID>
    let onPick: (UUID) -> Void
    let onNewChat: () -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    /// Substring match over titles. The full-text index behind
    /// `DataStore.searchConversations` searches message bodies too, which is
    /// the wrong shape here — this is a "which chat was that?" picker, and
    /// body hits would bury the title you're typing.
    private var results: [Conversation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return conversations }
        return conversations.filter { $0.title.lowercased().contains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider().overlay(AppTheme.Colors.divider)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if results.isEmpty {
                        Text(query.isEmpty ? "No conversations yet" : "No matches for \"\(query)\"")
                            .font(AppTheme.Typography.captionSecondary)
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, AppTheme.Spacing.xxl)
                    } else {
                        ForEach(results) { conversation in
                            row(for: conversation)
                        }
                    }
                }
                .padding(AppTheme.Spacing.sm)
            }
        }
        .frame(width: 460, height: 420)
        .background(AppTheme.Colors.backgroundPrimary)
        .onAppear { isSearchFocused = true }
    }

    private var searchField: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textTertiary)

                TextField("Search conversations…", text: $query)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .focused($isSearchFocused)
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }
                    .onSubmit {
                        // Return opens the top hit — the whole point of typing.
                        if let first = results.first { onPick(first.id) } else { onNewChat() }
                    }
            }

            Button(action: onNewChat) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                    Text("New Chat")
                        .font(AppTheme.Typography.callout)
                    Spacer()
                    Text("⌘N")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
                .foregroundStyle(AppTheme.Colors.accentPrimary)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                        .fill(AppTheme.Colors.hoverSubtle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(AppTheme.Spacing.lg)
    }

    private func row(for conversation: Conversation) -> some View {
        let isOpen = openTabIDs.contains(conversation.id)
        return Button {
            onPick(conversation.id)
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Text(conversation.displayEmoji)
                    .font(.system(size: 14))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(AppTheme.Typography.callout)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }

                Spacer()

                if isOpen {
                    Text("Open")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                .fill(isOpen ? AppTheme.Colors.hoverSubtle : Color.clear)
        }
    }
}
