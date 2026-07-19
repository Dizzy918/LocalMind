//
//  Project.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import Foundation

/// A workspace that groups conversations and carries defaults for them:
/// which agent answers, which knowledge collections ground answers, and
/// standing project context prepended to every chat inside.
///
/// Inheritance is live — resolved at generation time, so changing a
/// project's defaults affects its existing conversations too. Per-conversation
/// settings always win over project defaults.
nonisolated struct Project: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var emoji: String
    /// Default agent for conversations in this project; nil = default assistant.
    var agentID: UUID?
    /// Standing context appended to the system prompt of every chat inside.
    var systemPrompt: String?
    /// Knowledge collections project chats retrieve from; nil = all documents.
    var knowledgeCollections: [String]?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "📁",
        agentID: UUID? = nil,
        systemPrompt: String? = nil,
        knowledgeCollections: [String]? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.agentID = agentID
        self.systemPrompt = systemPrompt
        self.knowledgeCollections = knowledgeCollections
        self.createdAt = createdAt
    }
}
