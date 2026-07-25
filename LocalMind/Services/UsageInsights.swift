//
//  UsageInsights.swift
//  LocalMind
//
//  Local-only statistics computed from conversations already on disk.
//
//  Nothing is collected, tracked, or timed specially to produce these — they're
//  derived from what messages already record (model, agent, duration, token
//  counts). That matters for a project whose stated non-goals include telemetry:
//  the numbers never leave the machine because they're never gathered in the
//  first place, just counted on demand.
//
//  Pure and synchronous so the arithmetic is testable without a UI.
//

import Foundation

nonisolated struct UsageInsights: Sendable {
    /// Per-model throughput and volume.
    struct ModelStat: Sendable, Identifiable {
        let name: String
        var messages: Int
        /// Mean tokens/sec across answers that reported one.
        var averageTokensPerSecond: Double?
        /// Total completion tokens, when the backend reported them.
        var measuredTokens: Int?
        var id: String { name }
    }

    /// Per-agent usage.
    struct AgentStat: Sendable, Identifiable {
        let name: String
        let emoji: String?
        var messages: Int
        var id: String { name }
    }

    var totalConversations = 0
    var totalMessages = 0
    var assistantMessages = 0
    /// Sum of every recorded generation time.
    var totalGenerationSeconds: Double = 0
    /// Completion tokens the backends actually reported (nil when none did).
    var measuredCompletionTokens: Int?
    var models: [ModelStat] = []
    var agents: [AgentStat] = []
    /// Most active day, by message count.
    var busiestDay: (day: Date, messages: Int)?

    /// Mean tokens/sec weighted by nothing — a plain average of the per-answer
    /// figures, which is what a user reading "how fast is my setup" expects.
    var averageTokensPerSecond: Double? {
        let rates = models.compactMap(\.averageTokensPerSecond)
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }

    /// Whether any of the token figures came from a backend rather than the
    /// estimator, so the UI can avoid overclaiming precision.
    var hasMeasuredTokens: Bool { measuredCompletionTokens != nil }

    // MARK: - Computation

    static func compute(from conversations: [Conversation], calendar: Calendar = .current) -> UsageInsights {
        var insights = UsageInsights()
        insights.totalConversations = conversations.count

        var modelTotals: [String: (messages: Int, rates: [Double], tokens: Int?)] = [:]
        var agentTotals: [String: (emoji: String?, messages: Int)] = [:]
        var perDay: [Date: Int] = [:]

        for conversation in conversations {
            insights.totalMessages += conversation.messages.count

            for message in conversation.messages {
                let day = calendar.startOfDay(for: message.timestamp)
                perDay[day, default: 0] += 1

                guard message.role == .assistant else { continue }
                insights.assistantMessages += 1
                insights.totalGenerationSeconds += message.generationSeconds ?? 0

                let model = message.modelUsed ?? "Unknown"
                var entry = modelTotals[model] ?? (0, [], nil)
                entry.messages += 1
                if let rate = message.tokensPerSecond { entry.rates.append(rate) }
                if let completion = message.completionTokens {
                    entry.tokens = (entry.tokens ?? 0) + completion
                    insights.measuredCompletionTokens = (insights.measuredCompletionTokens ?? 0) + completion
                }
                modelTotals[model] = entry

                if let agentName = message.agentName {
                    var agent = agentTotals[agentName] ?? (message.agentEmoji, 0)
                    agent.messages += 1
                    if agent.emoji == nil { agent.emoji = message.agentEmoji }
                    agentTotals[agentName] = agent
                }
            }
        }

        insights.models = modelTotals
            .map { name, value in
                ModelStat(
                    name: name,
                    messages: value.messages,
                    averageTokensPerSecond: value.rates.isEmpty
                        ? nil
                        : value.rates.reduce(0, +) / Double(value.rates.count),
                    measuredTokens: value.tokens
                )
            }
            .sorted { $0.messages > $1.messages }

        insights.agents = agentTotals
            .map { AgentStat(name: $0.key, emoji: $0.value.emoji, messages: $0.value.messages) }
            .sorted { $0.messages > $1.messages }

        if let busiest = perDay.max(by: { lhs, rhs in
            // Ties go to the more recent day so the figure doesn't jump back
            // and forth between two equally busy days.
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }) {
            insights.busiestDay = (busiest.key, busiest.value)
        }

        return insights
    }
}
