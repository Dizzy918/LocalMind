//
//  Conversation.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation

enum ToolType: String, Codable, Sendable, CaseIterable {
    // The core default tool
    case chat = "Chat"

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        }
    }

    var displayName: String { rawValue }

    /// Default emoji for this tool type (used as fallback when AI hasn't assigned one)
    var emoji: String {
        switch self {
        case .chat: return "💬"
        }
    }
    
    // Custom decoder prevents crashes when loading old files containing 
    // removed tools (like "Summarizer"), gracefully converting them to standard Chat.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ToolType(rawValue: rawValue) ?? .chat
    }
}

struct Conversation: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let toolType: ToolType
    var customToolID: String?    // Used if toolType == .chat but it's a custom tool
    var customIconName: String? // Legacy: SF Symbol icon (kept for backward compat)
    var emoji: String?           // AI-generated topic emoji for easy recognition
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        messages: [ChatMessage] = [],
        toolType: ToolType = .chat,
        customToolID: String? = nil,
        customIconName: String? = nil,
        emoji: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.toolType = toolType
        self.customToolID = customToolID
        self.customIconName = customIconName
        self.emoji = emoji
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Returns the conversation's emoji, falling back to the tool type's default
    var displayEmoji: String {
        emoji ?? toolType.emoji
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
