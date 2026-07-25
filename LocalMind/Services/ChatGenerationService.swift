//
//  ChatGenerationService.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import Foundation

/// Picks which agent should answer a message in auto-route mode.
/// Pure functions so routing behaviour is unit-testable.
nonisolated enum AgentRouter {
    /// Builds the classification prompt listing every agent.
    static func routingPrompt(question: String, agents: [Agent]) -> String {
        let menu = agents.map { agent in
            let blurb = agent.tagline.isEmpty ? String(agent.systemPrompt.prefix(60)) : agent.tagline
            return "- \(agent.name): \(blurb)"
        }.joined(separator: "\n")
        return """
        Pick the single best specialist to answer the user's message.

        Specialists:
        \(menu)

        User message: "\(question.prefix(400))"

        Reply with EXACTLY one specialist name from the list, nothing else.
        """
    }

    /// Maps the model's (possibly chatty) reply back to an agent.
    ///
    /// Tries an exact match first; otherwise finds agent names mentioned in
    /// the reply and picks the one that appears *last* — reasoning models
    /// often think out loud about several candidates before naming their
    /// final choice at the end.
    static func match(reply: String, agents: [Agent]) -> Agent? {
        let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }

        if let exact = agents.first(where: { $0.name.lowercased() == cleaned }) {
            return exact
        }

        return agents
            .compactMap { agent -> (agent: Agent, position: String.Index)? in
                guard let range = cleaned.range(of: agent.name.lowercased(), options: .backwards) else { return nil }
                return (agent, range.lowerBound)
            }
            .max { $0.position < $1.position }?
            .agent
    }
}

/// Runs chat generations in the background, keyed by conversation ID.
///
/// ChatView used to own the streaming state, which meant switching
/// conversations (or closing the view) killed an in-flight answer. Moving
/// the pipeline here lets any number of conversations generate in parallel:
/// the view just renders `live[conversation.id]`, and finished answers are
/// appended to the conversation in `DataStore` whether or not it's on screen.
@Observable
@MainActor
final class ChatGenerationService {
    /// Streaming state for one conversation's in-flight generation.
    struct LiveGeneration {
        var text = ""
        var isStreaming = true
        /// Attribution for the streaming bubble (set when an agent answers).
        var agentName: String?
        var agentEmoji: String?
    }

    /// In-flight generations by conversation ID. Empty entry = nothing running.
    private(set) var live: [UUID: LiveGeneration] = [:]

    /// Conversations whose generation finished while the user was elsewhere.
    /// The sidebar shows these with an unread dot; ChatView clears its own
    /// entry whenever it's visible.
    private(set) var unseenFinished: Set<UUID> = []

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Earlier answers to carry into the next generation as per-turn variants
    /// (set when the user re-rolls the latest answer).
    private var pendingVariants: [UUID: [String]] = [:]
    /// Conversations with a rolling-summary refresh in flight.
    private var summaryTasks: Set<UUID> = []

    private let dataStore: DataStore
    private let aiManager: AIServiceManager

    init(dataStore: DataStore, aiManager: AIServiceManager) {
        self.dataStore = dataStore
        self.aiManager = aiManager
    }

    // MARK: - View-facing State

    func isStreaming(_ conversationID: UUID) -> Bool {
        live[conversationID]?.isStreaming ?? false
    }

    func streamingText(_ conversationID: UUID) -> String {
        live[conversationID]?.text ?? ""
    }

    func liveAttribution(_ conversationID: UUID) -> (name: String?, emoji: String?) {
        let state = live[conversationID]
        return (state?.agentName, state?.agentEmoji)
    }

    func hasUnseenReply(_ conversationID: UUID) -> Bool {
        unseenFinished.contains(conversationID)
    }

    func markSeen(_ conversationID: UUID) {
        unseenFinished.remove(conversationID)
    }

    /// How many conversations are generating right now.
    var activeGenerationCount: Int {
        live.values.filter(\.isStreaming).count
    }

    /// Whether a detected backend can serve a generation right now. Lets
    /// callers that fire autonomously (scheduled runs) hold off instead of
    /// burning their attempt on a guaranteed "no backend" failure.
    var hasAvailableBackend: Bool {
        aiManager.currentService != nil
    }

    /// Stops every in-flight generation, keeping partial answers.
    func stopAll() {
        for id in Array(live.keys) where live[id]?.isStreaming == true {
            stop(conversationID: id)
        }
    }

    // MARK: - Control

    /// Starts generating the next assistant turn for a conversation. The
    /// conversation (including the just-appended user message) must already
    /// be saved in the data store.
    func start(conversationID: UUID, oneShotModel: String? = nil, carryVariants: [String]? = nil) {
        guard !isStreaming(conversationID) else { return }
        if let carryVariants {
            pendingVariants[conversationID] = carryVariants
        }
        live[conversationID] = LiveGeneration()
        tasks[conversationID] = Task {
            await run(conversationID: conversationID, oneShotModel: oneShotModel)
        }
    }

    /// Cancels a conversation's in-flight generation, keeping any partial
    /// text as a "[Generation stopped]" message.
    func stop(conversationID: UUID) {
        tasks[conversationID]?.cancel()
        tasks[conversationID] = nil

        if let state = live[conversationID],
           case let split = state.text.separatingThinkBlocks, !split.answer.isEmpty,
           var conversation = dataStore.conversations.first(where: { $0.id == conversationID }) {
            var partial = ChatMessage(role: .assistant, content: split.answer + "\n\n*[Generation stopped]*")
            partial.reasoning = split.reasoning
            partial.agentName = state.agentName
            partial.agentEmoji = state.agentEmoji
            if let pending = pendingVariants[conversationID] {
                partial.variants = pending + [partial.content]
                partial.activeVariantIndex = pending.count
            }
            conversation.messages.append(partial)
            conversation.updatedAt = Date()
            dataStore.saveConversation(conversation)
        }
        pendingVariants[conversationID] = nil
        live[conversationID] = nil
    }

    // MARK: - Automation

    enum AutomationError: Error, LocalizedError {
        case noBackend
        case timedOut
        case empty

        var errorDescription: String? {
            switch self {
            case .noBackend: return "No AI backend is connected. Start Ollama or another local server and try again."
            case .timedOut: return "The model took too long to answer."
            case .empty: return "The model didn't return an answer."
            }
        }
    }

    /// Runs one prompt to completion and returns the answer text, for callers
    /// with no UI to stream into (App Intents, Shortcuts).
    ///
    /// This deliberately goes through the normal `start` pipeline rather than
    /// calling the service directly, so an automated ask gets the same
    /// treatment as a typed one: the agent's persona, project and personal
    /// context, knowledge-base retrieval, cross-chat memory, and tool calls.
    /// A one-shot `generateOnce` would quietly skip all of it.
    ///
    /// - Parameter keepInHistory: when false the conversation is removed once
    ///   the answer is read, so a Shortcut that runs on a loop doesn't fill the
    ///   sidebar.
    func generateForAutomation(
        prompt: String,
        agentName: String? = nil,
        keepInHistory: Bool = true,
        timeout: TimeInterval = 180
    ) async throws -> String {
        guard hasAvailableBackend else { throw AutomationError.noBackend }

        var conversation = Conversation(
            title: String(prompt.prefix(50)) + (prompt.count > 50 ? "…" : ""),
            messages: [ChatMessage(role: .user, content: prompt)]
        )
        if let agentName,
           let agent = dataStore.agents.first(where: { $0.name.caseInsensitiveCompare(agentName) == .orderedSame }) {
            conversation.agentID = agent.id
            conversation.emoji = agent.emoji
        }
        dataStore.saveConversation(conversation)
        let id = conversation.id

        start(conversationID: id)

        let deadline = Date().addingTimeInterval(timeout)
        while isStreaming(id) {
            if Date() >= deadline {
                stop(conversationID: id)
                if !keepInHistory { removeAutomationConversation(id) }
                throw AutomationError.timedOut
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        let answer = dataStore.conversations
            .first { $0.id == id }?
            .messages.last { $0.role == .assistant }?
            .content ?? ""

        // The pipeline reports failures as an assistant message rather than by
        // throwing, so an automation caller has to be told it actually failed
        // instead of receiving "⚠️ …" as if it were an answer.
        if answer.hasPrefix("⚠️") {
            if !keepInHistory { removeAutomationConversation(id) }
            throw AutomationError.noBackend
        }

        if !keepInHistory { removeAutomationConversation(id) }
        markSeen(id)

        guard !answer.isEmpty else { throw AutomationError.empty }
        return answer
    }

    private func removeAutomationConversation(_ id: UUID) {
        guard let conversation = dataStore.conversations.first(where: { $0.id == id }) else { return }
        dataStore.deleteConversation(conversation)
    }

    // MARK: - Prompt Resolution

    /// Builds the effective system prompt for a conversation: global default
    /// (or custom-tool prompt), replaced by the agent's instructions, replaced
    /// by the per-conversation override — with the active profile's Personal
    /// Context prepended and the owning project's context appended. Shared
    /// with the compare view so alternatives are produced under identical
    /// conditions.
    func resolvedSystemPrompt(for conversation: Conversation, agent: Agent?) -> String {
        let fallback = "You are LocalMind, a helpful, concise AI assistant. Provide clear, actionable responses. Use markdown formatting when appropriate."
        var systemPrompt = UserDefaults.standard.string(forKey: "defaultSystemPrompt") ?? fallback
        if systemPrompt.isEmpty { systemPrompt = fallback }

        if let customToolID = conversation.customToolID,
           let customTool = dataStore.customTools.first(where: { $0.id == customToolID }) {
            systemPrompt = customTool.systemPrompt
        }

        if let agent, !agent.systemPrompt.isEmpty {
            systemPrompt = agent.systemPrompt
        }

        if let override = conversation.systemPromptOverride, !override.isEmpty {
            systemPrompt = override
        }

        // Project context composes (appends) rather than replaces — the
        // persona stays whoever is answering; the project supplies standing
        // background every chat inside should know.
        if let project = dataStore.project(withID: conversation.projectID),
           let projectPrompt = project.systemPrompt, !projectPrompt.isEmpty {
            systemPrompt += "\n\nProject context (\(project.name)):\n\(projectPrompt)"
        }

        let personalContext = ProfileStore.currentPersonalContext()
        if !personalContext.isEmpty {
            systemPrompt = personalContext + "\n\n---\n\n" + systemPrompt
        }
        return systemPrompt
    }

    /// The agent that will answer the next turn of this conversation —
    /// the conversation's own, falling back to its project's default.
    func assignedAgent(for conversation: Conversation) -> Agent? {
        if let own = dataStore.agent(withID: conversation.agentID) {
            return own
        }
        return dataStore.agent(withID: dataStore.project(withID: conversation.projectID)?.agentID)
    }

    // MARK: - Generation Pipeline

    private func run(conversationID: UUID, oneShotModel: String?) async {
        defer {
            tasks[conversationID] = nil
        }

        guard var conversation = dataStore.conversations.first(where: { $0.id == conversationID }) else {
            live[conversationID] = nil
            return
        }

        func appendFailure(_ text: String) {
            conversation.messages.append(ChatMessage(role: .assistant, content: text))
            conversation.updatedAt = Date()
            dataStore.saveConversation(conversation)
            live[conversationID] = nil
            pendingVariants[conversationID] = nil
        }

        let lastUserMessage = conversation.messages.last(where: { $0.role == .user })?.content ?? ""

        // Resolve who answers: auto-routing picks a specialist per message,
        // otherwise the conversation's assigned agent (or none).
        var agent = assignedAgent(for: conversation)
        if conversation.autoRouteAgent, dataStore.agents.count >= 1, !lastUserMessage.isEmpty {
            if let routed = await routeAgent(for: lastUserMessage) {
                agent = routed
            }
        }
        if Task.isCancelled { return }

        live[conversationID]?.agentName = agent?.name
        live[conversationID]?.agentEmoji = agent?.emoji

        // Resolve the service, honouring a cross-backend pin.
        guard let service = await aiManager.service(matching: agent?.backend) else {
            let error = AIServiceError.noBackendAvailable
            appendFailure("⚠️ \(error.localizedDescription)\n\n💡 \(error.recoverySuggestion ?? "")")
            return
        }
        if Task.isCancelled { return }

        var systemPrompt = resolvedSystemPrompt(for: conversation, agent: agent)

        // Retrieval-augmented generation, enabled globally or by the agent.
        // Agents can narrow retrieval to their subscribed collections.
        var retrievedSources: [MessageSource] = []
        // A project that subscribes to collections implies its chats want the
        // knowledge base even when the global toggle is off. Empty (a legacy
        // save of "restrict to nothing") doesn't count — retrieval would treat
        // it as unrestricted.
        let project = dataStore.project(withID: conversation.projectID)
        let knowledgeEnabled = UserDefaults.standard.bool(forKey: "useKnowledgeBase")
            || (agent?.useKnowledgeBase ?? false)
            || project?.knowledgeCollections?.isEmpty == false
        if knowledgeEnabled, !lastUserMessage.isEmpty {
            let hits = await KnowledgeBaseStore.shared.retrieve(
                lastUserMessage,
                collections: agent?.knowledgeCollections ?? project?.knowledgeCollections
            )
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
                retrievedSources = hits.map {
                    MessageSource(documentName: $0.documentName, snippet: String($0.text.prefix(180)))
                }
            }
        }
        if Task.isCancelled { return }

        // Cross-conversation memory: recall similar exchanges from other
        // chats (opt-in), so "as we discussed last week" actually works.
        if UserDefaults.standard.bool(forKey: "rememberPastChats"), !lastUserMessage.isEmpty {
            let memories = await ChatMemoryStore.shared.recall(lastUserMessage, excluding: conversationID)
            if !memories.isEmpty {
                let lines = memories
                    .map { "- [\($0.title), \($0.date.formatted(date: .abbreviated, time: .omitted))] \($0.text)" }
                    .joined(separator: "\n")
                systemPrompt += """


                Relevant moments from the user's past conversations (bring them up only when helpful):
                \(lines)
                """
            }
        }
        if Task.isCancelled { return }

        var effectiveParameters = aiManager.aiParameters
        if let temperature = conversation.temperatureOverride ?? agent?.temperature {
            effectiveParameters.temperature = temperature
        }

        // Context selection: the user's message cap AND the model's token
        // budget both apply, so a handful of huge messages can't overflow the
        // context window (which used to silently truncate mid-prompt).
        let contextLimit = UserDefaults.standard.integer(forKey: "contextMessageLimit")
        let maxMessages = contextLimit > 0 ? contextLimit : 10
        let tokenBudget = max(
            512,
            (effectiveParameters.contextLength ?? 4096) - TokenEstimator.estimate(systemPrompt) - 1024
        )
        let selection = Self.selectContext(
            messages: conversation.messages,
            maxMessages: maxMessages,
            tokenBudget: tokenBudget
        )
        let recentMessages = selection.included

        // When older turns fell out of the window, stand in for them with the
        // rolling summary (refreshed in the background after each answer).
        if selection.excludedCount > 0,
           let summary = conversation.contextSummary,
           conversation.summarizedMessageCount > 0 {
            systemPrompt += """


            Earlier in this conversation (summary of older messages that no longer fit the context window):
            \(summary)
            """
        }

        // Model resolution, most specific first: one-shot > conversation pin >
        // agent pin > global. An agent pinned to another backend passes its
        // model straight through (that backend's server validates it); an
        // agent on the current backend only applies its model when the
        // backend actually offers it.
        let agentModel: String?
        if let pinned = agent?.modelID {
            if agent?.backend != nil, agent?.backend != aiManager.currentBackend {
                agentModel = pinned
            } else {
                agentModel = aiManager.allAvailableModelIDs.contains(pinned) ? pinned : nil
            }
        } else {
            agentModel = nil
        }
        let effectiveModel = oneShotModel ?? conversation.modelOverride ?? agentModel

        // Tools: agents can disable them outright or limit them to a named
        // subset. MCP execution is backend-independent, so cross-backend
        // agents keep their tools.
        let tools = aiManager.tools(for: agent)

        let generationStart = Date()

        do {
            // Streams the answer and runs any MCP tools the model calls,
            // feeding results back for a follow-up turn until it answers
            // without tools. The visible text lands in `live` via onDelta.
            // Tool calls are approval-gated downstream in MCPService.callTool.
            let outcome = try await aiManager.streamChatWithTools(
                service: service,
                messages: recentMessages,
                systemPrompt: systemPrompt,
                modelOverride: effectiveModel,
                parameters: effectiveParameters,
                tools: tools,
                shouldContinue: { !Task.isCancelled },
                onDelta: { delta in
                    self.live[conversationID]?.text += delta
                }
            )
            // The persisted answer excludes the live tool markers — the
            // message's tool transcript renders those properly instead.
            let rawText = outcome.text

            // Past the stream everything is gated on cancellation: stop()
            // already appended the partial message and cleared the live state,
            // so a late return must not produce a second, orphaned message.
            if !Task.isCancelled {
                let (reasoning, finalText) = rawText.separatingThinkBlocks
                if !finalText.isEmpty {
                    var assistantMessage = ChatMessage(role: .assistant, content: finalText)
                    assistantMessage.reasoning = reasoning
                    if !retrievedSources.isEmpty {
                        assistantMessage.sources = retrievedSources
                    }
                    assistantMessage.agentName = agent?.name
                    assistantMessage.agentEmoji = agent?.emoji
                    assistantMessage.modelUsed = effectiveModel ?? defaultModelLabel(for: service.backend)
                    if !outcome.toolRuns.isEmpty {
                        assistantMessage.toolRuns = outcome.toolRuns
                    }

                    // Performance stats. Prefer the backend's own token counts
                    // and generation time — TokenEstimator is a heuristic, and
                    // wall-clock includes prompt evaluation and tool time that
                    // aren't generation. Fall back to the estimate only when
                    // the backend reported nothing.
                    let seconds = Date().timeIntervalSince(generationStart)
                    assistantMessage.generationSeconds = seconds
                    assistantMessage.promptTokens = outcome.usage?.promptTokens
                    assistantMessage.completionTokens = outcome.usage?.completionTokens

                    if let completion = outcome.usage?.completionTokens,
                       let generating = outcome.usage?.generationSeconds, generating > 0 {
                        assistantMessage.tokensPerSecond = Double(completion) / generating
                    } else if let completion = outcome.usage?.completionTokens, seconds > 0.2 {
                        assistantMessage.tokensPerSecond = Double(completion) / seconds
                    } else if seconds > 0.2 {
                        assistantMessage.tokensPerSecond = Double(TokenEstimator.estimate(outcome.displayText)) / seconds
                    }

                    if let pending = pendingVariants[conversationID] {
                        assistantMessage.variants = pending + [finalText]
                        assistantMessage.activeVariantIndex = pending.count
                    }

                    // Re-read the conversation: the user may have renamed it
                    // (or the title/emoji tasks may have written) mid-stream.
                    if let fresh = dataStore.conversations.first(where: { $0.id == conversationID }) {
                        conversation = fresh
                    }
                    conversation.messages.append(assistantMessage)
                    conversation.updatedAt = Date()
                    dataStore.saveConversation(conversation)
                    unseenFinished.insert(conversationID)

                    // Post-generation housekeeping, both off the critical path:
                    // remember this exchange, and refresh the rolling summary
                    // if older messages have fallen out of the window.
                    let finished = conversation
                    Task { await ChatMemoryStore.shared.indexConversation(finished) }
                    scheduleRollingSummary(conversationID: conversationID, excludedCount: selection.excludedCount)
                }
                pendingVariants[conversationID] = nil
                live[conversationID] = nil
            }
        } catch {
            if !Task.isCancelled {
                let description: String
                if let serviceError = error as? AIServiceError {
                    description = "⚠️ \(serviceError.localizedDescription)\n\n💡 \(serviceError.recoverySuggestion ?? "")"
                } else if (error as NSError).code == NSURLErrorTimedOut {
                    let timeout = AIServiceError.timeout
                    description = "⚠️ \(timeout.localizedDescription)\n\n💡 \(timeout.recoverySuggestion ?? "")"
                } else {
                    description = "⚠️ Error: \(error.localizedDescription)"
                }
                if let fresh = dataStore.conversations.first(where: { $0.id == conversationID }) {
                    conversation = fresh
                }
                appendFailure(description)
            }
        }
    }

    // MARK: - Context Selection

    /// Picks the newest messages that fit both the message cap and the token
    /// budget. Always includes the newest message, even when it alone blows
    /// the budget — the backend truncating one message beats sending nothing.
    nonisolated static func selectContext(messages: [ChatMessage], maxMessages: Int, tokenBudget: Int) -> (included: [ChatMessage], excludedCount: Int) {
        var included: [ChatMessage] = []
        var usedTokens = 0
        for message in messages.suffix(maxMessages).reversed() {
            let cost = TokenEstimator.estimate(message.content)
            if !included.isEmpty && usedTokens + cost > tokenBudget { break }
            included.insert(message, at: 0)
            usedTokens += cost
        }
        return (included, messages.count - included.count)
    }

    /// Refreshes the rolling summary of messages that no longer fit the
    /// context window. Runs in the background after an answer lands; the next
    /// turn picks the summary up from the saved conversation.
    private func scheduleRollingSummary(conversationID: UUID, excludedCount: Int) {
        guard excludedCount > 0,
              !summaryTasks.contains(conversationID),
              let conversation = dataStore.conversations.first(where: { $0.id == conversationID }),
              excludedCount > conversation.summarizedMessageCount,
              excludedCount <= conversation.messages.count else { return }

        summaryTasks.insert(conversationID)
        Task {
            defer { summaryTasks.remove(conversationID) }
            guard let service = aiManager.currentService else { return }

            // Summarize incrementally: fold only the newly excluded messages
            // into the previous summary instead of re-reading everything.
            let newlyExcluded = conversation.messages[conversation.summarizedMessageCount..<excludedCount]
            var source = ""
            if let previous = conversation.contextSummary, !previous.isEmpty {
                source += "Summary so far:\n\(previous)\n\nNewer messages to fold in:\n"
            }
            source += newlyExcluded
                .map { "\($0.role == .user ? "User" : "Assistant"): \(String($0.content.prefix(500)))" }
                .joined(separator: "\n")

            let prompt = """
            Condense this conversation into a running summary under 200 words. \
            Keep concrete facts, names, decisions, and anything the user asked to remember. \
            Output only the summary.

            \(String(source.prefix(8000)))
            """
            guard let reply = try? await service.generateOnce(
                prompt: prompt,
                systemPrompt: "You maintain a compact running summary of a conversation.",
                modelOverride: nil,
                parameters: AIParameters(temperature: 0.2),
                tools: nil
            ) else { return }

            let summary = reply.strippingThinkBlocks
            guard !summary.isEmpty,
                  var fresh = dataStore.conversations.first(where: { $0.id == conversationID }) else { return }
            fresh.contextSummary = summary
            fresh.summarizedMessageCount = excludedCount
            dataStore.saveConversation(fresh)
        }
    }

    /// Asks the current model which agent fits the question best. Fast, cheap
    /// classification — temperature 0, no tools.
    private func routeAgent(for question: String) async -> Agent? {
        let agents = dataStore.agents
        guard !agents.isEmpty, let service = aiManager.currentService else { return nil }
        if agents.count == 1 { return agents[0] }

        let prompt = AgentRouter.routingPrompt(question: question, agents: agents)
        guard let reply = try? await service.generateOnce(
            prompt: prompt,
            systemPrompt: "You are a router. Output only one name from the list, nothing else.",
            modelOverride: nil,
            parameters: AIParameters(temperature: 0.0),
            tools: nil
        ) else { return nil }
        return AgentRouter.match(reply: reply, agents: agents)
    }

    /// Human-readable default model for a backend, for message attribution
    /// when no explicit model was pinned.
    private func defaultModelLabel(for backend: AIBackend) -> String? {
        switch backend {
        case .ollama: return aiManager.selectedOllamaModel
        case .openAICompatible: return aiManager.selectedOpenAIModel
        case .appleFoundationModels: return "Apple Intelligence"
        case .none: return nil
        }
    }
}
