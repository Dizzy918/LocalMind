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
    var isPinned: Bool           // Pinned conversations float to the top of the sidebar
    var isArchived: Bool         // Archived conversations are hidden by default
    var systemPromptOverride: String?  // Per-conversation prompt; nil falls back to the global default
    var modelOverride: String?         // Per-conversation model id; nil = use the globally selected model
    var temperatureOverride: Double?   // Per-conversation temperature; nil = use the global parameter
    var profileID: UUID?               // Owning profile. nil = orphan (pre-profiles legacy data).
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
        isPinned: Bool = false,
        isArchived: Bool = false,
        systemPromptOverride: String? = nil,
        modelOverride: String? = nil,
        temperatureOverride: Double? = nil,
        profileID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.toolType = toolType
        self.customToolID = customToolID
        self.customIconName = customIconName
        self.emoji = emoji
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.systemPromptOverride = systemPromptOverride
        self.modelOverride = modelOverride
        self.temperatureOverride = temperatureOverride
        self.profileID = profileID
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // Backward-compatible decoding — old files won't have isPinned/isArchived/profileID.
    enum CodingKeys: String, CodingKey {
        case id, title, messages, toolType, customToolID, customIconName, emoji
        case isPinned, isArchived, systemPromptOverride, profileID, createdAt, updatedAt
        case modelOverride, temperatureOverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.messages = try c.decode([ChatMessage].self, forKey: .messages)
        self.toolType = try c.decode(ToolType.self, forKey: .toolType)
        self.customToolID = try c.decodeIfPresent(String.self, forKey: .customToolID)
        self.customIconName = try c.decodeIfPresent(String.self, forKey: .customIconName)
        self.emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.systemPromptOverride = try c.decodeIfPresent(String.self, forKey: .systemPromptOverride)
        self.modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        self.temperatureOverride = try c.decodeIfPresent(Double.self, forKey: .temperatureOverride)
        self.profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(messages, forKey: .messages)
        try c.encode(toolType, forKey: .toolType)
        try c.encodeIfPresent(customToolID, forKey: .customToolID)
        try c.encodeIfPresent(customIconName, forKey: .customIconName)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encodeIfPresent(systemPromptOverride, forKey: .systemPromptOverride)
        try c.encodeIfPresent(modelOverride, forKey: .modelOverride)
        try c.encodeIfPresent(temperatureOverride, forKey: .temperatureOverride)
        try c.encodeIfPresent(profileID, forKey: .profileID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
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
