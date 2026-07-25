//
//  UsageInsightsView.swift
//  LocalMind
//
//  Local-only usage statistics. Everything shown is derived on demand from
//  conversations already on disk — nothing is collected or reported, which is
//  what keeps this consistent with the project's no-telemetry promise.
//

import SwiftUI

struct UsageInsightsView: View {
    let dataStore: DataStore

    @State private var insights = UsageInsights()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                header

                if insights.assistantMessages == 0 {
                    emptyState
                } else {
                    summaryGrid
                    if !insights.models.isEmpty { modelsSection }
                    if !insights.agents.isEmpty { agentsSection }
                }

                Spacer(minLength: 0)
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: recompute)
        // Recompute when history changes rather than caching — this is cheap
        // next to what it's summarising, and stale stats are worse than none.
        .onChange(of: dataStore.conversations.count) { _, _ in recompute() }
    }

    private func recompute() {
        insights = UsageInsights.compute(from: dataStore.conversationsForActiveProfile(includeArchived: true))
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Usage")
                .font(AppTheme.Typography.title)
            Text("Counted from your own chat history on this Mac. Nothing is collected or sent anywhere.")
                .font(AppTheme.Typography.captionSecondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        Text("No answers yet — stats appear once you've chatted.")
            .font(AppTheme.Typography.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, AppTheme.Spacing.xl)
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AppTheme.Spacing.sm)],
                  spacing: AppTheme.Spacing.sm) {
            statTile("Conversations", value: "\(insights.totalConversations)")
            statTile("Answers", value: "\(insights.assistantMessages)")
            statTile("Messages", value: "\(insights.totalMessages)")
            if let rate = insights.averageTokensPerSecond {
                statTile("Avg speed", value: String(format: "%.1f tok/s", rate))
            }
            if insights.totalGenerationSeconds > 0 {
                statTile("Time generating", value: formattedDuration(insights.totalGenerationSeconds))
            }
            if let tokens = insights.measuredCompletionTokens {
                statTile("Tokens generated", value: formattedCount(tokens),
                         footnote: "counted by the model server")
            }
            if let busiest = insights.busiestDay {
                statTile("Busiest day",
                         value: busiest.day.formatted(date: .abbreviated, time: .omitted),
                         footnote: "\(busiest.messages) messages")
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("By model")
                .font(.system(size: 13, weight: .semibold))
            ForEach(insights.models) { model in
                HStack {
                    Text(model.name)
                        .font(AppTheme.Typography.body)
                        .lineLimit(1)
                    Spacer()
                    if let rate = model.averageTokensPerSecond {
                        Text(String(format: "%.1f tok/s", rate))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(model.messages)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: 6).fill(AppTheme.Colors.backgroundSecondary.opacity(0.5)))
            }
        }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("By agent")
                .font(.system(size: 13, weight: .semibold))
            ForEach(insights.agents) { agent in
                HStack {
                    Text("\(agent.emoji ?? "🤖") \(agent.name)")
                        .font(AppTheme.Typography.body)
                        .lineLimit(1)
                    Spacer()
                    Text("\(agent.messages)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: 6).fill(AppTheme.Colors.backgroundSecondary.opacity(0.5)))
            }
        }
    }

    // MARK: - Bits

    private func statTile(_ label: String, value: String, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            if let footnote {
                Text(footnote)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.Colors.backgroundSecondary.opacity(0.6)))
    }

    private func formattedDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3600 { return String(format: "%.0fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3600)
    }

    private func formattedCount(_ value: Int) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000)
            : value >= 1_000 ? String(format: "%.1fk", Double(value) / 1_000)
            : "\(value)"
    }
}
