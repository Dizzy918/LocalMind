//
//  Conversation.swift
//  LocalAIHelper
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation

enum ToolType: String, Codable, Sendable, CaseIterable {
    case chat = "Chat"
    case grammarFixer = "Grammar Fixer"
    case summarizer = "Summarizer"
    case taskPlanner = "Task Planner"
    case emailDrafter = "Email Drafter"
    case codeHelper = "Code Helper"
    case gitCommit = "Git Commits"
    case focusTimer = "Focus Timer"
    case promptVault = "Prompt Vault"

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .grammarFixer: return "text.badge.checkmark"
        case .summarizer: return "doc.text.magnifyingglass"
        case .taskPlanner: return "checklist"
        case .emailDrafter: return "envelope"
        case .codeHelper: return "chevron.left.forwardslash.chevron.right"
        case .gitCommit: return "arrow.triangle.branch"
        case .focusTimer: return "timer"
        case .promptVault: return "archivebox"
        }
    }

    var displayName: String { rawValue }
}

struct Conversation: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let toolType: ToolType
    var customIcon: String? // Stores the AI-generated context icon
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        messages: [ChatMessage] = [],
        toolType: ToolType = .chat,
        customIcon: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.toolType = toolType
        self.customIcon = customIcon
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Auto-generate title from first user message
    mutating func updateTitleIfNeeded() {
        if title == "New Conversation",
           let firstUserMessage = messages.first(where: { $0.role == .user }) {
            let preview = String(firstUserMessage.content.prefix(50))
            title = preview + (firstUserMessage.content.count > 50 ? "..." : "")
        }
    }
}
