//
//  AgentTeamView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Run several agents against the same prompt at once.
///
/// Each selected agent streams its answer into its own column concurrently.
/// Afterwards the user can copy an answer, continue any column as a normal
/// chat with that agent pinned, or ask for a synthesis that merges all
/// answers into one.
struct AgentTeamView: View {
    let aiManager: AIServiceManager
    let dataStore: DataStore
    let onClose: () -> Void

    /// Per-agent streaming state for the current run.
    private struct TeamRun {
        var text = ""
        var error: String?
        var isStreaming = true
    }

    private static let maxAgents = 4

    // Ordered selection so columns keep the order the user picked.
    @State private var selectedAgentIDs: [UUID] = []
    @State private var prompt = ""
    // Agents captured at launch time — editing the selection mid-run must not
    // reshuffle the columns.
    @State private var runAgents: [Agent] = []
    @State private var runs: [UUID: TeamRun] = [:]
    @State private var runTasks: [UUID: Task<Void, Never>] = [:]

    @State private var synthesisText = ""
    @State private var isSynthesizing = false
    @State private var synthesisTask: Task<Void, Never>?

    // Debate: 1 = first answers, 2+ = revision rounds where each agent has
    // seen (and argued against) the others' previous answers.
    @State private var round = 0
    @State private var verdictText = ""
    @State private var isJudging = false
    @State private var judgeTask: Task<Void, Never>?

    @FocusState private var promptFocused: Bool

    private var isRunning: Bool {
        runs.values.contains { $0.isStreaming }
    }

    private var allFinished: Bool {
        !runAgents.isEmpty && !isRunning
    }

    private var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedAgentIDs.isEmpty
            && !isRunning
            && aiManager.currentService != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            header
            agentChips
            promptRow
            Divider()
            if round >= 2 {
                HStack(spacing: 6) {
                    Image(systemName: "person.line.dotted.person")
                        .font(.system(size: 11))
                    Text("Debate — round \(round): revised answers")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(AppTheme.Colors.accentPrimary)
            }
            resultsArea
            if allFinished, runAgents.count >= 2 {
                postRunArea
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(
            minWidth: 760, idealWidth: max(760, CGFloat(max(runAgents.count, 2)) * 340),
            maxWidth: .infinity, minHeight: 560, idealHeight: 640, maxHeight: .infinity
        )
        .onAppear {
            // Preselect the first two agents so a first run is one click away.
            if selectedAgentIDs.isEmpty {
                selectedAgentIDs = dataStore.agents.prefix(2).map(\.id)
            }
            promptFocused = true
        }
        .onDisappear { cancelAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Team")
                    .font(AppTheme.Typography.headline)
                Text("Send one prompt to several agents at once and compare — or combine — their answers.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Agent selection

    private var agentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.sm) {
                ForEach(dataStore.agents) { agent in
                    agentChip(agent)
                }
                if dataStore.agents.isEmpty {
                    Text("No agents yet — create some in Settings → Agents.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func agentChip(_ agent: Agent) -> some View {
        let isSelected = selectedAgentIDs.contains(agent.id)
        let selectionFull = selectedAgentIDs.count >= Self.maxAgents
        return Button {
            if isSelected {
                selectedAgentIDs.removeAll { $0 == agent.id }
            } else if !selectionFull {
                selectedAgentIDs.append(agent.id)
            }
        } label: {
            HStack(spacing: 4) {
                Text(agent.emoji)
                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(isSelected
                    ? AppTheme.Colors.accentPrimary.opacity(0.18)
                    : AppTheme.Colors.backgroundSecondary)
            }
            .overlay {
                Capsule().stroke(
                    isSelected ? AppTheme.Colors.accentPrimary : AppTheme.Colors.border,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .opacity(!isSelected && selectionFull ? 0.4 : 1)
        .disabled(isRunning)
        .help(agent.tagline.isEmpty ? agent.name : agent.tagline)
    }

    // MARK: - Prompt

    private var promptRow: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
            TextField("Ask all selected agents…", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(AppTheme.Typography.body)
                .lineLimit(1...4)
                .focused($promptFocused)
                .onSubmit { if canRun { run() } }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                        .fill(AppTheme.Colors.backgroundSecondary)
                        .overlay {
                            RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                                .stroke(AppTheme.Colors.border, lineWidth: 1)
                        }
                }

            if isRunning {
                Button {
                    cancelAll()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    run()
                } label: {
                    Label(runAgents.isEmpty ? "Run" : "Run again", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: - Results

    /// Selected agents in selection order — the columns shown before a run.
    private var selectedAgents: [Agent] {
        selectedAgentIDs.compactMap { id in dataStore.agents.first { $0.id == id } }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if runAgents.isEmpty && selectedAgents.isEmpty {
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "person.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                Text("Pick up to \(Self.maxAgents) agents, type a prompt, and run them side by side.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if runAgents.isEmpty {
            // Selection preview — who's on the team and what each will run on,
            // shown before the first prompt goes out.
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(selectedAgents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 { Divider() }
                    agentPreviewColumn(agent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8).stroke(AppTheme.Colors.border, lineWidth: 1)
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(runAgents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 { Divider() }
                    agentColumn(agent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8).stroke(AppTheme.Colors.border, lineWidth: 1)
            }
        }
    }

    /// Pre-run column: the agent's card — persona, backend & model, abilities.
    private func agentPreviewColumn(_ agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: 6) {
                Text(agent.emoji)
                Text(agent.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
            }

            Text(aiManager.resolvedModelDescription(for: agent))
                .font(AppTheme.Typography.captionSecondary)
                .foregroundStyle(AppTheme.Colors.accentPrimary)
                .lineLimit(1)

            if !agent.tagline.isEmpty {
                Text(agent.tagline)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(String(agent.systemPrompt.prefix(160)) + (agent.systemPrompt.count > 160 ? "…" : ""))
                .font(AppTheme.Typography.captionSecondary)
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack(spacing: AppTheme.Spacing.sm) {
                if agent.useKnowledgeBase {
                    Label("Knowledge", systemImage: "books.vertical")
                }
                if let temperature = agent.temperature {
                    Label(String(format: "%.2f", temperature), systemImage: "thermometer.medium")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(AppTheme.Colors.textTertiary)

            Text("Waiting for your prompt")
                .font(AppTheme.Typography.captionSecondary)
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .italic()
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func agentColumn(_ agent: Agent) -> some View {
        let run = runs[agent.id] ?? TeamRun(text: "", error: nil, isStreaming: false)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: 6) {
                Text(agent.emoji)
                Text(agent.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                if run.isStreaming {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(aiManager.resolvedModelDescription(for: agent))
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .help("The backend and model this agent answered with")
                }
            }

            ScrollView {
                if run.text.isEmpty && run.isStreaming {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MessageMarkdownView(text: run.error.map { run.text + "\n\n⚠️ \($0)" } ?? run.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    copyToPasteboard(run.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(run.text.isEmpty || run.isStreaming)

                Button {
                    continueAsChat(agent: agent, answer: run.text)
                } label: {
                    Label("Open as chat", systemImage: "bubble.left.and.text.bubble.right")
                }
                .controlSize(.small)
                .disabled(run.text.isEmpty || run.isStreaming)
                .help("Save this exchange as a conversation with \(agent.name) and keep talking")
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Synthesis

    /// Follow-up actions once a round has finished: argue another round,
    /// have a moderator pick a winner, or merge everything into one answer.
    private var postRunArea: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    startDebateRound()
                } label: {
                    Label(round >= 2 ? "Another round" : "Debate round", systemImage: "person.line.dotted.person")
                }
                .help("Each agent reads the others' answers, critiques them, and revises its own")

                Button {
                    moderatorVerdict()
                } label: {
                    Label("Moderator verdict", systemImage: "checkmark.seal")
                }
                .disabled(isJudging)
                .help("An impartial moderator declares the winning answer")

                if synthesisText.isEmpty && !isSynthesizing {
                    Button {
                        synthesize()
                    } label: {
                        Label("Synthesize", systemImage: "arrow.triangle.merge")
                    }
                    .help("Combine all answers into one, resolving disagreements")
                }
                Spacer()
            }

            if !verdictText.isEmpty || isJudging {
                resultPanel(
                    title: "Moderator verdict",
                    icon: "checkmark.seal",
                    text: verdictText,
                    isWorking: isJudging
                )
            }

            if !synthesisText.isEmpty || isSynthesizing {
                resultPanel(
                    title: "Synthesis",
                    icon: "arrow.triangle.merge",
                    text: synthesisText,
                    isWorking: isSynthesizing
                )
            }
        }
    }

    private func resultPanel(title: String, icon: String, text: String, isWorking: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accentPrimary)
                if isWorking { ProgressView().controlSize(.mini) }
                Spacer()
                Button {
                    copyToPasteboard(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(text.isEmpty || isWorking)
            }
            ScrollView {
                MessageMarkdownView(text: text.isEmpty ? "Working…" : text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(AppTheme.Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.Colors.accentPrimary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.Colors.accentPrimary.opacity(0.4), lineWidth: 1)
                    }
            }
        }
    }

    // MARK: - Actions

    private func run() {
        guard aiManager.currentService != nil else { return }
        cancelAll()

        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let agents = selectedAgentIDs.compactMap { id in dataStore.agents.first { $0.id == id } }
        guard !question.isEmpty, !agents.isEmpty else { return }

        runAgents = agents
        runs = [:]
        round = 1
        synthesisText = ""
        isSynthesizing = false
        verdictText = ""
        isJudging = false

        for agent in agents {
            launchAgentTask(agent: agent, userContent: question)
        }
    }

    /// Debate: each agent reads everyone's previous answers, critiques them,
    /// and streams a revised answer into a fresh round of columns.
    private func startDebateRound() {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = runAgents.compactMap { agent -> (agent: Agent, answer: String)? in
            guard let text = runs[agent.id]?.text, !text.isEmpty else { return nil }
            return (agent, text)
        }
        guard previous.count >= 2 else { return }

        round += 1
        synthesisText = ""
        verdictText = ""

        for agent in runAgents {
            let own = previous.first { $0.agent.id == agent.id }?.answer ?? "(you gave no answer)"
            let others = previous
                .filter { $0.agent.id != agent.id }
                .map { "[\($0.agent.name)]:\n\($0.answer)" }
                .joined(separator: "\n\n")
            let debatePrompt = """
            The question under debate: \(question)

            Your previous answer:
            \(own)

            The other panelists answered:
            \(others)

            Point out where the other panelists are wrong — or concede where their \
            arguments are stronger — then give your single revised final answer. \
            Be direct, and change your position if a better argument exists.
            """
            launchAgentTask(agent: agent, userContent: debatePrompt)
        }
    }

    /// Streams one agent's answer to `userContent` into its column. Shared by
    /// the first run and every debate round.
    private func launchAgentTask(agent: Agent, userContent: String) {
        runs[agent.id] = TeamRun()

        let personalContext = ProfileStore.currentPersonalContext()

        // Cross-backend pins pass their model straight through (their own
        // server validates it); same-backend pins only apply when the
        // backend actually offers the model.
        let model: String?
        if let pinned = agent.modelID {
            if let backend = agent.backend, backend != aiManager.currentBackend {
                model = pinned
            } else {
                model = aiManager.allAvailableModelIDs.contains(pinned) ? pinned : nil
            }
        } else {
            model = nil
        }
        let parameters: AIParameters = {
            var params = aiManager.aiParameters
            if let temperature = agent.temperature {
                params.temperature = temperature
            }
            return params
        }()

        // Only tools with standing approval are exposed in team runs, so four
        // agents can't race each other through one approval dialog. The
        // agent's own allowlist narrows that set further.
        let preApproved = Set(aiManager.mcpService?.toolNamesNotRequiringApproval ?? [])
        var agentTools = agent.allowTools
            ? aiManager.getAvailableTools().filter { preApproved.contains($0.name) }
            : []
        if let allowed = agent.allowedToolIDs {
            agentTools = agentTools.filter { allowed.contains($0.name) }
        }
        let tools = agentTools.isEmpty ? nil : agentTools

        runTasks[agent.id] = Task {
            // Each agent resolves its own backend, so one team can mix
            // e.g. Ollama and Apple Intelligence and run them truly in
            // parallel. Unreachable pins fall back to the current service.
            guard let service = await aiManager.service(matching: agent.backend) else {
                runs[agent.id]?.error = AIServiceError.noBackendAvailable.localizedDescription
                runs[agent.id]?.isStreaming = false
                return
            }
            var systemPrompt = agent.systemPrompt
            if !personalContext.isEmpty {
                systemPrompt = personalContext + "\n\n---\n\n" + systemPrompt
            }
            // Ground knowledge-base agents in their documents (respecting
            // their collection subscriptions), same as normal chats.
            if agent.useKnowledgeBase {
                let hits = await KnowledgeBaseStore.shared.retrieve(userContent, collections: agent.knowledgeCollections)
                if !hits.isEmpty {
                    let excerpts = hits.enumerated()
                        .map { "[\($0.offset + 1)] (\($0.element.documentName)) \($0.element.text)" }
                        .joined(separator: "\n\n")
                    systemPrompt = """
                    The user has shared personal documents. Use the excerpts below to answer when they're relevant, and say so plainly if they don't contain the answer. Don't invent details they don't support.

                    <documents>
                    \(excerpts)
                    </documents>

                    \(systemPrompt)
                    """
                }
            }

            do {
                // Streams the answer and runs any tools the agent calls,
                // feeding results back so the agent can actually use them (the
                // arena runs tools without a per-agent approval prompt).
                _ = try await aiManager.streamChatWithTools(
                    service: service,
                    messages: [ChatMessage(role: .user, content: userContent)],
                    systemPrompt: systemPrompt,
                    modelOverride: model,
                    parameters: parameters,
                    tools: tools,
                    shouldContinue: { !Task.isCancelled },
                    onDelta: { delta in
                        runs[agent.id]?.text += delta
                    }
                )
            } catch {
                if !Task.isCancelled {
                    runs[agent.id]?.error = error.localizedDescription
                }
            }
            // Drop hidden <think> reasoning so copies, saved chats, and
            // the synthesis prompt only carry the visible answer.
            if let raw = runs[agent.id]?.text {
                runs[agent.id]?.text = raw.strippingThinkBlocks
            }
            runs[agent.id]?.isStreaming = false
        }
    }

    /// An impartial moderator reads all answers and declares a winner.
    private func moderatorVerdict() {
        guard let service = aiManager.currentService, !isJudging else { return }
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let answers = runAgents.compactMap { agent -> String? in
            guard let text = runs[agent.id]?.text, !text.isEmpty else { return nil }
            return "[\(agent.name)]:\n\(text)"
        }
        guard answers.count >= 2 else { return }

        isJudging = true
        verdictText = ""
        let judgePrompt = """
        You are an impartial debate moderator. The question: \(question)

        The panelists' answers:
        \(answers.joined(separator: "\n\n"))

        Declare the single best answer. Start with "Winner: <name>", then justify \
        the call in under 100 words, noting anything the winner still got wrong.
        """

        judgeTask = Task {
            do {
                for try await chunk in service.streamChat(
                    messages: [ChatMessage(role: .user, content: judgePrompt)],
                    systemPrompt: "You are a fair, decisive moderator. No fence-sitting.",
                    modelOverride: nil,
                    parameters: AIParameters(temperature: 0.3),
                    tools: nil
                ) {
                    if Task.isCancelled { break }
                    if case .text(let text) = chunk { verdictText += text }
                }
            } catch {
                if !Task.isCancelled {
                    verdictText += "\n\n⚠️ \(error.localizedDescription)"
                }
            }
            verdictText = verdictText.strippingThinkBlocks
            isJudging = false
        }
    }

    private func cancelAll() {
        for task in runTasks.values { task.cancel() }
        runTasks = [:]
        synthesisTask?.cancel()
        synthesisTask = nil
        isSynthesizing = false
        judgeTask?.cancel()
        judgeTask = nil
        isJudging = false
        for id in runs.keys { runs[id]?.isStreaming = false }
    }

    private func synthesize() {
        guard let service = aiManager.currentService, !isSynthesizing else { return }
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let answers = runAgents.compactMap { agent -> String? in
            guard let text = runs[agent.id]?.text, !text.isEmpty else { return nil }
            return "### \(agent.name)\n\(text)"
        }
        guard answers.count >= 2 else { return }

        isSynthesizing = true
        synthesisText = ""
        let synthesisPrompt = """
        Several AI agents with different specialties each answered the same question. \
        Combine their answers into one final answer that keeps the best of each. Where \
        they disagree, say so explicitly and state which position is better supported and why. \
        Do not mention the agents' names or that multiple answers existed — just produce \
        the single best answer.

        Question: \(question)

        \(answers.joined(separator: "\n\n"))
        """

        synthesisTask = Task {
            do {
                for try await chunk in service.streamChat(
                    messages: [ChatMessage(role: .user, content: synthesisPrompt)],
                    systemPrompt: "You are an expert editor who merges multiple drafts into one definitive answer.",
                    modelOverride: nil,
                    parameters: aiManager.aiParameters,
                    tools: nil
                ) {
                    if Task.isCancelled { break }
                    if case .text(let text) = chunk { synthesisText += text }
                }
            } catch {
                if !Task.isCancelled {
                    synthesisText += "\n\n⚠️ \(error.localizedDescription)"
                }
            }
            synthesisText = synthesisText.strippingThinkBlocks
            isSynthesizing = false
        }
    }

    /// Saves the exchange as a real conversation pinned to this agent, then
    /// asks the main window to open it so the user can keep talking.
    private func continueAsChat(agent: Agent, answer: String) {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var conversation = Conversation(
            title: String(question.prefix(50)) + (question.count > 50 ? "..." : ""),
            messages: [
                ChatMessage(role: .user, content: question),
                ChatMessage(role: .assistant, content: answer)
            ],
            toolType: .chat,
            emoji: agent.emoji,
            agentID: agent.id
        )
        conversation.updatedAt = Date()
        dataStore.saveConversation(conversation)
        NotificationCenter.default.post(name: .openConversation, object: conversation.id)
        onClose()
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
