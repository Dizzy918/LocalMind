//
//  AgentPipeline.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import Foundation

/// One stage of a pipeline: which agent runs it and what it should do with
/// the previous stage's output.
nonisolated struct PipelineStep: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    /// Agent that runs this step; nil = the default assistant.
    var agentID: UUID?
    /// What this step does — e.g. "Critique the draft for factual errors".
    var instruction: String

    init(id: UUID = UUID(), agentID: UUID? = nil, instruction: String = "") {
        self.id = id
        self.agentID = agentID
        self.instruction = instruction
    }
}

/// A reusable chain of agents: each step receives the previous step's output
/// and transforms it — draft → critique → revise, research → summarize, etc.
nonisolated struct AgentPipeline: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var emoji: String
    var steps: [PipelineStep]
    let createdAt: Date

    init(id: UUID = UUID(), name: String, emoji: String = "🔗", steps: [PipelineStep] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.steps = steps
        self.createdAt = createdAt
    }
}
