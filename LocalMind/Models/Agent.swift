//
//  Agent.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import Foundation

/// A reusable AI persona: a system prompt plus optional model, temperature,
/// and capability settings.
///
/// Agents are the unit of "who is answering": a conversation can pin one
/// agent, and the Agent Team panel can run several agents against the same
/// prompt in parallel. Unlike a `CustomTool` (which only swaps the system
/// prompt), an agent also carries its own model choice, creativity level,
/// and whether it may use MCP tools or the local knowledge base.
nonisolated struct Agent: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var emoji: String
    /// One-line description shown in pickers ("Skeptical code reviewer").
    var tagline: String
    var systemPrompt: String
    /// Backend to answer on; nil = whatever backend is currently connected.
    /// Lets one team run mix e.g. Ollama and Apple Intelligence agents.
    var backend: AIBackend?
    /// Model to answer with; nil = whatever model is globally selected.
    var modelID: String?
    /// Generation temperature; nil = the global parameter.
    var temperature: Double?
    /// Whether MCP tools are exposed to this agent.
    var allowTools: Bool
    /// Specific MCP tool names this agent may call; nil = all tools.
    /// Only consulted while `allowTools` is true.
    var allowedToolIDs: [String]?
    /// Whether answers should be grounded in the local document store.
    var useKnowledgeBase: Bool
    /// Named knowledge collections this agent retrieves from; nil = all
    /// documents. Only consulted while `useKnowledgeBase` is true.
    var knowledgeCollections: [String]?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "🤖",
        tagline: String = "",
        systemPrompt: String,
        backend: AIBackend? = nil,
        modelID: String? = nil,
        temperature: Double? = nil,
        allowTools: Bool = true,
        allowedToolIDs: [String]? = nil,
        useKnowledgeBase: Bool = false,
        knowledgeCollections: [String]? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.tagline = tagline
        self.systemPrompt = systemPrompt
        self.backend = backend
        self.modelID = modelID
        self.temperature = temperature
        self.allowTools = allowTools
        self.allowedToolIDs = allowedToolIDs
        self.useKnowledgeBase = useKnowledgeBase
        self.knowledgeCollections = knowledgeCollections
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // Tolerant decoding so agent files survive future field additions the
    // same way Conversation does.
    enum CodingKeys: String, CodingKey {
        case id, name, emoji, tagline, systemPrompt, backend, modelID, temperature
        case allowTools, allowedToolIDs, useKnowledgeBase, knowledgeCollections, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "🤖"
        self.tagline = try c.decodeIfPresent(String.self, forKey: .tagline) ?? ""
        self.systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        // try? so an unrecognized backend string from a newer build reads as
        // "current backend" instead of failing the whole file.
        self.backend = try? c.decodeIfPresent(AIBackend.self, forKey: .backend)
        self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        self.allowTools = try c.decodeIfPresent(Bool.self, forKey: .allowTools) ?? true
        self.allowedToolIDs = try c.decodeIfPresent([String].self, forKey: .allowedToolIDs)
        self.useKnowledgeBase = try c.decodeIfPresent(Bool.self, forKey: .useKnowledgeBase) ?? false
        self.knowledgeCollections = try c.decodeIfPresent([String].self, forKey: .knowledgeCollections)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - Starter Templates

extension Agent {
    /// Fresh copies of the built-in starter personas. Used to seed the agent
    /// list on first launch and as "start from template" options in the
    /// editor. Each call mints new IDs so a template can be added repeatedly.
    static func starterTemplates() -> [Agent] {
        [
            Agent(
                name: "Researcher",
                emoji: "🔎",
                tagline: "Digs into your documents and cites sources",
                systemPrompt: """
                You are a meticulous research assistant. Ground every claim in the provided \
                documents or clearly say when you are reasoning from general knowledge. \
                Quote or cite the relevant passage when you use one. If the question is \
                ambiguous, state your interpretation before answering. Prefer structured, \
                scannable answers with short sections.
                """,
                temperature: 0.3,
                useKnowledgeBase: true
            ),
            Agent(
                name: "Coder",
                emoji: "💻",
                tagline: "Code-first answers with minimal prose",
                systemPrompt: """
                You are an expert software engineer. Answer with working code first, then a \
                brief explanation of the non-obvious parts only. Match the language and \
                style the user is using. Point out bugs, edge cases, and performance \
                problems when you see them. Never invent APIs — say when you're unsure.
                """,
                temperature: 0.2
            ),
            Agent(
                name: "Writer",
                emoji: "✍️",
                tagline: "Drafts and polishes prose in your voice",
                systemPrompt: """
                You are a skilled writer and editor. Produce clear, engaging prose with \
                varied sentence rhythm and no filler. When editing, preserve the author's \
                voice and explain significant changes. Offer one alternative phrasing for \
                key sentences when it could land better.
                """,
                temperature: 0.9
            ),
            Agent(
                name: "Critic",
                emoji: "🧐",
                tagline: "Stress-tests ideas and finds the holes",
                systemPrompt: """
                You are a constructive skeptic. Your job is to find weaknesses: hidden \
                assumptions, missing evidence, failure modes, and stronger counter-arguments. \
                Steelman the idea first in one sentence, then list the most serious problems \
                in order of impact, and end with what would change your mind.
                """,
                temperature: 0.4
            )
        ]
    }
}
