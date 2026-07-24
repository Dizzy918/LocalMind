//
//  ChatGenerationServiceTests.swift
//  LocalMindTests
//
//  End-to-end tests for the background generation pipeline using a
//  scriptable mock backend: parallel conversations, cancellation,
//  variants, attribution, auto-routing, and think-block stripping.
//

import XCTest
@testable import LocalMind

// MARK: - Mock backend

/// Scriptable AIServiceProtocol: streams canned chunks (with optional
/// per-chunk delay) and records every call it receives.
final class MockAIService: AIServiceProtocol, @unchecked Sendable {
    struct StreamCall: Sendable {
        let messageContents: [String]
        let messageRoles: [String]
        let systemPrompt: String?
        let modelOverride: String?
        let temperature: Double?
        let toolNames: [String]?
    }

    let backendName = "Mock"
    let backend: AIBackend = .ollama

    private let lock = NSLock()
    private var _streamCalls: [StreamCall] = []
    private var _onceCalls: [String] = []

    var streamCalls: [StreamCall] {
        lock.lock(); defer { lock.unlock() }
        return _streamCalls
    }

    var onceCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _onceCalls
    }

    /// Chunks yielded by streamChat, in order.
    var chunks: [String]
    /// Delay before each chunk, for cancellation-timing tests.
    var chunkDelayNanos: UInt64
    /// Reply for generateOnce (used by auto-routing).
    var generateOnceReply: String
    /// When set, streamChat fails with this error instead of yielding.
    var errorToThrow: Error?
    /// When non-empty, each streamChat call consumes the next element and
    /// yields exactly those chunks (for tool-loop tests). Overrides `chunks`.
    private var _scriptedRounds: [[AIStreamChunk]] = []
    var scriptedRounds: [[AIStreamChunk]] {
        get { lock.lock(); defer { lock.unlock() }; return _scriptedRounds }
        set { lock.lock(); _scriptedRounds = newValue; lock.unlock() }
    }

    init(chunks: [String] = ["Hello", " world"],
         chunkDelayNanos: UInt64 = 0,
         generateOnceReply: String = "OK") {
        self.chunks = chunks
        self.chunkDelayNanos = chunkDelayNanos
        self.generateOnceReply = generateOnceReply
    }

    func checkAvailability() async -> Bool { true }

    func streamChat(messages: [ChatMessage], systemPrompt: String?, modelOverride: String?, parameters: AIParameters?, tools: [AITool]?) -> AsyncThrowingStream<AIStreamChunk, Error> {
        lock.lock()
        _streamCalls.append(StreamCall(
            messageContents: messages.map(\.content),
            messageRoles: messages.map { $0.role.rawValue },
            systemPrompt: systemPrompt,
            modelOverride: modelOverride,
            temperature: parameters?.temperature,
            toolNames: tools.map { $0.map(\.name) }
        ))
        // A scripted round takes precedence over the plain text chunks.
        let scripted: [AIStreamChunk]? = _scriptedRounds.isEmpty ? nil : _scriptedRounds.removeFirst()
        lock.unlock()

        let chunks = self.chunks
        let delay = self.chunkDelayNanos
        let error = self.errorToThrow
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                if let scripted {
                    for chunk in scripted {
                        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                    }
                    continuation.yield(.done)
                    continuation.finish()
                    return
                }
                for chunk in chunks {
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    if Task.isCancelled { break }
                    continuation.yield(.text(chunk))
                }
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func generateOnce(prompt: String, systemPrompt: String?, modelOverride: String?, parameters: AIParameters?, tools: [AITool]?) async throws -> String {
        lock.lock()
        _onceCalls.append(prompt)
        lock.unlock()
        return generateOnceReply
    }
}

// MARK: - Generation pipeline tests

@MainActor
final class ChatGenerationServiceTests: XCTestCase {

    var dataStore: DataStore!
    var aiManager: AIServiceManager!
    var generationService: ChatGenerationService!
    var mock: MockAIService!
    var testDir: URL!
    private var savedKnowledgeFlag: Bool!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        dataStore = DataStore(baseDirectoryOverride: testDir)
        aiManager = AIServiceManager()
        mock = MockAIService()
        aiManager.setServiceForTesting(mock)
        generationService = ChatGenerationService(dataStore: dataStore, aiManager: aiManager)

        // Pin the defaults the pipeline reads so a developer's real settings
        // can't change test behaviour.
        savedKnowledgeFlag = UserDefaults.standard.bool(forKey: "useKnowledgeBase")
        UserDefaults.standard.set(false, forKey: "useKnowledgeBase")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedKnowledgeFlag, forKey: "useKnowledgeBase")
        try? FileManager.default.removeItem(at: testDir)
        dataStore = nil
        aiManager = nil
        generationService = nil
        mock = nil
        super.tearDown()
    }

    // MARK: Helpers

    /// Creates, saves, and returns a conversation ending in a user message.
    private func makeConversation(question: String = "Hi there", agentID: UUID? = nil, autoRoute: Bool = false) -> Conversation {
        var conversation = Conversation(
            title: "Test",
            messages: [ChatMessage(role: .user, content: question)],
            agentID: agentID
        )
        conversation.autoRouteAgent = autoRoute
        dataStore.saveConversation(conversation)
        return conversation
    }

    private func storedConversation(_ id: UUID) -> Conversation? {
        dataStore.conversations.first { $0.id == id }
    }

    /// Waits (yielding the main actor) until the generation finishes.
    private func waitForFinish(_ id: UUID, timeout: TimeInterval = 5) async {
        let start = Date()
        while generationService.isStreaming(id), Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits until some streamed text is visible for the conversation.
    private func waitForFirstText(_ id: UUID, timeout: TimeInterval = 5) async {
        let start = Date()
        while generationService.streamingText(id).isEmpty,
              generationService.isStreaming(id),
              Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Core pipeline

    func testGenerationAppendsAssistantMessage() async {
        let conversation = makeConversation()

        generationService.start(conversationID: conversation.id)
        XCTAssertTrue(generationService.isStreaming(conversation.id))
        await waitForFinish(conversation.id)

        let stored = storedConversation(conversation.id)
        XCTAssertEqual(stored?.messages.count, 2)
        XCTAssertEqual(stored?.messages.last?.role, .assistant)
        XCTAssertEqual(stored?.messages.last?.content, "Hello world")
        XCTAssertNotNil(stored?.messages.last?.modelUsed, "answers should record which model produced them")
        XCTAssertFalse(generationService.isStreaming(conversation.id))
        XCTAssertTrue(generationService.hasUnseenReply(conversation.id))

        generationService.markSeen(conversation.id)
        XCTAssertFalse(generationService.hasUnseenReply(conversation.id))
    }

    func testParallelGenerationsAcrossConversations() async {
        mock.chunks = ["answer"]
        mock.chunkDelayNanos = 100_000_000 // 100ms — long enough to overlap

        let first = makeConversation(question: "First question")
        let second = makeConversation(question: "Second question")

        generationService.start(conversationID: first.id)
        generationService.start(conversationID: second.id)

        // Both must be in flight at the same time — this is the whole point
        // of moving generation out of the view.
        XCTAssertTrue(generationService.isStreaming(first.id))
        XCTAssertTrue(generationService.isStreaming(second.id))

        await waitForFinish(first.id)
        await waitForFinish(second.id)

        XCTAssertEqual(storedConversation(first.id)?.messages.last?.content, "answer")
        XCTAssertEqual(storedConversation(second.id)?.messages.last?.content, "answer")
        XCTAssertEqual(mock.streamCalls.count, 2)
    }

    func testStopMidStreamKeepsPartialAndNeverDoubleAppends() async {
        mock.chunks = Array(repeating: "chunk ", count: 100)
        mock.chunkDelayNanos = 20_000_000 // 20ms per chunk

        let conversation = makeConversation()
        generationService.start(conversationID: conversation.id)
        await waitForFirstText(conversation.id)

        generationService.stop(conversationID: conversation.id)

        let afterStop = storedConversation(conversation.id)
        XCTAssertEqual(afterStop?.messages.count, 2)
        XCTAssertTrue(afterStop?.messages.last?.content.contains("[Generation stopped]") ?? false)
        XCTAssertTrue(afterStop?.messages.last?.content.contains("chunk") ?? false)
        XCTAssertFalse(generationService.isStreaming(conversation.id))

        // Give the cancelled task time to unwind — it must not append a
        // second assistant message.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(storedConversation(conversation.id)?.messages.count, 2)
    }

    func testThinkBlocksAreStrippedFromFinalMessage() async {
        mock.chunks = ["<think>", "chain of thought here", "</think>", "\n\nThe answer is 4."]

        let conversation = makeConversation(question: "2+2?")
        generationService.start(conversationID: conversation.id)
        await waitForFinish(conversation.id)

        XCTAssertEqual(storedConversation(conversation.id)?.messages.last?.content, "The answer is 4.")
    }

    func testCarryVariantsBecomeTurnVariants() async {
        mock.chunks = ["fresh answer"]

        let conversation = makeConversation()
        generationService.start(conversationID: conversation.id, carryVariants: ["old answer"])
        await waitForFinish(conversation.id)

        let last = storedConversation(conversation.id)?.messages.last
        XCTAssertEqual(last?.variants, ["old answer", "fresh answer"])
        XCTAssertEqual(last?.activeVariantIndex, 1)
        XCTAssertEqual(last?.content, "fresh answer")
    }

    func testStreamErrorAppendsReadableErrorMessage() async {
        mock.errorToThrow = AIServiceError.serverError("boom")

        let conversation = makeConversation()
        generationService.start(conversationID: conversation.id)
        await waitForFinish(conversation.id)

        let last = storedConversation(conversation.id)?.messages.last
        XCTAssertEqual(last?.role, .assistant)
        XCTAssertTrue(last?.content.contains("⚠️") ?? false)
        XCTAssertTrue(last?.content.contains("boom") ?? false)
        XCTAssertFalse(generationService.isStreaming(conversation.id))
    }

    // MARK: Agents in the pipeline

    func testAgentPromptTemperatureAndAttribution() async {
        let agent = Agent(
            name: "TestCoder",
            emoji: "🧪",
            systemPrompt: "You are TestCoder, answer tersely.",
            temperature: 0.25
        )
        dataStore.saveAgent(agent)
        mock.chunks = ["short answer"]

        let conversation = makeConversation(agentID: agent.id)
        generationService.start(conversationID: conversation.id)
        await waitForFinish(conversation.id)

        let call = mock.streamCalls.first
        XCTAssertTrue(call?.systemPrompt?.contains("You are TestCoder") ?? false)
        XCTAssertEqual(call?.temperature, 0.25)

        let last = storedConversation(conversation.id)?.messages.last
        XCTAssertEqual(last?.agentName, "TestCoder")
        XCTAssertEqual(last?.agentEmoji, "🧪")
    }

    func testAutoRouteSelectsAgentFromModelReply() async {
        let researcher = Agent(name: "Researcher", emoji: "🔎", tagline: "Digs deep", systemPrompt: "Research.")
        let coder = Agent(name: "Coder", emoji: "💻", tagline: "Writes code", systemPrompt: "Code.")
        dataStore.saveAgent(researcher)
        dataStore.saveAgent(coder)
        mock.generateOnceReply = "Coder"
        mock.chunks = ["routed answer"]

        let conversation = makeConversation(question: "Write me a sort function", autoRoute: true)
        generationService.start(conversationID: conversation.id)
        await waitForFinish(conversation.id)

        XCTAssertEqual(mock.onceCalls.count, 1, "auto-route should classify exactly once per message")
        XCTAssertTrue(mock.onceCalls.first?.contains("Pick the single best specialist") ?? false)

        let last = storedConversation(conversation.id)?.messages.last
        XCTAssertEqual(last?.agentName, "Coder")
        XCTAssertTrue(mock.streamCalls.first?.systemPrompt?.contains("Code.") ?? false,
                      "the routed agent's instructions should drive the answer")
    }

    func testStopAllStopsEveryConversation() async {
        mock.chunks = Array(repeating: "chunk ", count: 100)
        mock.chunkDelayNanos = 20_000_000

        let first = makeConversation(question: "one")
        let second = makeConversation(question: "two")
        generationService.start(conversationID: first.id)
        generationService.start(conversationID: second.id)
        XCTAssertEqual(generationService.activeGenerationCount, 2)

        await waitForFirstText(first.id)
        await waitForFirstText(second.id)
        generationService.stopAll()

        XCTAssertEqual(generationService.activeGenerationCount, 0)
        XCTAssertFalse(generationService.isStreaming(first.id))
        XCTAssertFalse(generationService.isStreaming(second.id))
        XCTAssertTrue(storedConversation(first.id)?.messages.last?.content.contains("[Generation stopped]") ?? false)
        XCTAssertTrue(storedConversation(second.id)?.messages.last?.content.contains("[Generation stopped]") ?? false)
    }

    func testAgentWithToolsDisabledSendsNoTools() async {
        let agent = Agent(name: "NoTools", systemPrompt: "Plain.", allowTools: false)
        dataStore.saveAgent(agent)

        let conversation = makeConversation(agentID: agent.id)
        generationService.start(conversationID: conversation.id)
        await waitForFinish(conversation.id)

        XCTAssertNil(mock.streamCalls.first?.toolNames ?? nil)
    }

    // MARK: Tool loop

    private func tool(_ name: String) -> AITool {
        AITool(id: name, name: name, description: "", inputSchema: AnyCodable([String: String]()))
    }

    func testToolLoopFeedsResultsBackAndProducesFinalAnswer() async throws {
        // Round 1 asks for a tool; round 2 answers. The loop must run the tool,
        // feed its result back, and let the model produce the final answer.
        mock.scriptedRounds = [
            [.text("Let me check."), .toolCalls([AIToolCall(id: "call_1", name: "get_time", arguments: "{}")])],
            [.text("It is noon.")]
        ]

        var delivered = ""
        let outcome = try await aiManager.streamChatWithTools(
            service: mock,
            messages: [ChatMessage(role: .user, content: "what time is it?")],
            systemPrompt: "sys",
            modelOverride: nil,
            parameters: .default,
            tools: [tool("get_time")],
            onDelta: { delivered += $0 }
        )

        XCTAssertTrue(outcome.text.contains("Let me check."))
        XCTAssertTrue(outcome.text.contains("It is noon."), "the follow-up answer must appear")
        // The persisted answer stays clean — the marker belongs to the live
        // stream and the transcript, not to the saved message text.
        XCTAssertFalse(outcome.text.contains("🔧"), "tool markers must not leak into the persisted answer")
        XCTAssertTrue(outcome.displayText.contains("get_time"), "the live stream marks what ran")
        XCTAssertEqual(delivered, outcome.displayText, "onDelta must mirror the display text exactly")

        XCTAssertEqual(mock.streamCalls.count, 2, "the model should be re-invoked after the tool ran")
        // The second round must carry the assistant tool-call turn and the
        // tool result back to the model.
        XCTAssertTrue(mock.streamCalls.last?.messageRoles.contains("assistant") ?? false)
        XCTAssertTrue(mock.streamCalls.last?.messageRoles.contains("tool") ?? false)
    }

    func testToolLoopStopsAtRoundCap() async throws {
        // A model that always asks for a tool must not loop forever.
        mock.scriptedRounds = Array(
            repeating: [.toolCalls([AIToolCall(id: "c", name: "spin", arguments: "{}")])],
            count: 20
        )

        _ = try await aiManager.streamChatWithTools(
            service: mock,
            messages: [ChatMessage(role: .user, content: "go")],
            systemPrompt: "s",
            modelOverride: nil,
            parameters: .default,
            tools: [tool("spin")],
            maxToolRounds: 5,
            onDelta: { _ in }
        )

        // 5 tool rounds, then a 6th stream call whose calls are refused by the cap.
        XCTAssertEqual(mock.streamCalls.count, 6)
    }

    func testNoToolsMeansSingleRound() async throws {
        // Even if the model emits a tool call, passing tools: nil means we
        // never loop — the text of that turn is the answer.
        mock.scriptedRounds = [
            [.text("Answer."), .toolCalls([AIToolCall(id: "x", name: "ghost", arguments: "{}")])]
        ]

        let outcome = try await aiManager.streamChatWithTools(
            service: mock,
            messages: [ChatMessage(role: .user, content: "hi")],
            systemPrompt: "s",
            modelOverride: nil,
            parameters: .default,
            tools: nil,
            onDelta: { _ in }
        )

        XCTAssertEqual(outcome.text, "Answer.")
        XCTAssertTrue(outcome.toolRuns.isEmpty)
        XCTAssertEqual(mock.streamCalls.count, 1)
    }

    func testToolRunsArePersistedOnTheAssistantMessage() async throws {
        // Without an MCP backend wired up the call fails — which is exactly the
        // case worth recording: the transcript must capture failures too, and
        // survive on the message rather than living only in the session log.
        mock.scriptedRounds = [
            [.toolCalls([AIToolCall(id: "call_1", name: "lookup", arguments: "{\"q\":\"swift\"}")])],
            [.text("Here's what I found.")]
        ]

        let outcome = try await aiManager.streamChatWithTools(
            service: mock,
            messages: [ChatMessage(role: .user, content: "look it up")],
            systemPrompt: "s",
            modelOverride: nil,
            parameters: .default,
            tools: [tool("lookup")],
            onDelta: { _ in }
        )

        XCTAssertEqual(outcome.toolRuns.count, 1)
        let run = try XCTUnwrap(outcome.toolRuns.first)
        XCTAssertEqual(run.name, "lookup")
        XCTAssertEqual(run.arguments, "{\"q\":\"swift\"}")
        XCTAssertFalse(run.result.isEmpty, "a run always records what came back")
        XCTAssertTrue(run.isError, "no MCP backend means the call couldn't run — recorded, not swallowed")
        // No backend means nothing was executed, so there's nothing to time.
        XCTAssertNil(run.seconds)

        // And the whole thing round-trips through the message's Codable form.
        var message = ChatMessage(role: .assistant, content: outcome.text)
        message.toolRuns = outcome.toolRuns
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.toolRuns?.first?.name, "lookup")
        XCTAssertEqual(decoded.toolRuns?.first?.arguments, "{\"q\":\"swift\"}")
    }

    // MARK: Token usage

    func testBackendReportedUsageBeatsTheEstimator() async {
        // Ollama reports real counts on its final chunk. When it does, the
        // stats must use them (and eval_duration) instead of TokenEstimator.
        mock.scriptedRounds = [[
            .text("A short answer."),
            .usage(AIUsage(promptTokens: 40, completionTokens: 20, generationSeconds: 2.0))
        ]]

        let conversation = makeConversation()
        generationService.start(conversationID: conversation.id)
        await waitForFinish(conversation.id)

        let last = storedConversation(conversation.id)?.messages.last
        XCTAssertEqual(last?.promptTokens, 40)
        XCTAssertEqual(last?.completionTokens, 20)
        XCTAssertEqual(last?.tokensPerSecond ?? 0, 10.0, accuracy: 0.001,
                       "20 tokens over the backend's 2s of generation")
        XCTAssertTrue(last?.hasMeasuredTokens ?? false)
    }

    func testUsageIsSummedAcrossToolRounds() async throws {
        // Each tool round is its own backend call, so the answer's cost is
        // every round added together.
        mock.scriptedRounds = [
            [.text("Checking."),
             .toolCalls([AIToolCall(id: "c1", name: "peek", arguments: "{}")]),
             .usage(AIUsage(promptTokens: 10, completionTokens: 5, generationSeconds: 1.0))],
            [.text("Done."),
             .usage(AIUsage(promptTokens: 30, completionTokens: 15, generationSeconds: 2.0))]
        ]

        let outcome = try await aiManager.streamChatWithTools(
            service: mock,
            messages: [ChatMessage(role: .user, content: "go")],
            systemPrompt: "s",
            modelOverride: nil,
            parameters: .default,
            tools: [tool("peek")],
            onDelta: { _ in }
        )

        XCTAssertEqual(outcome.usage?.promptTokens, 40)
        XCTAssertEqual(outcome.usage?.completionTokens, 20)
        XCTAssertEqual(outcome.usage?.generationSeconds ?? 0, 3.0, accuracy: 0.001)
    }

    func testBackendWithoutUsageFallsBackToTheEstimator() async {
        // Apple Intelligence and several OpenAI-compatible servers report
        // nothing — the stats must still appear, just estimated.
        mock.chunks = ["Some answer text here."]

        let conversation = makeConversation()
        generationService.start(conversationID: conversation.id)
        await waitForFinish(conversation.id)

        let last = storedConversation(conversation.id)?.messages.last
        XCTAssertNil(last?.completionTokens)
        XCTAssertFalse(last?.hasMeasuredTokens ?? true)
    }

    func testMissingCountsAreNotTreatedAsZero() {
        // A backend reporting nothing must not drag a real total down to 0.
        XCTAssertNil(sum(nil as Int?, nil as Int?))
        XCTAssertEqual(sum(5, nil), 5)
        XCTAssertEqual(sum(nil, 7), 7)
        XCTAssertEqual(sum(5, 7), 12)
    }

    func testToolRunPrettyPrintsArgumentsAndToleratesGarbage() {
        let valid = ToolRun(name: "t", arguments: "{\"b\":2,\"a\":1}", result: "ok")
        XCTAssertTrue(valid.formattedArguments.contains("\n"), "valid JSON is pretty-printed")
        XCTAssertTrue(valid.formattedArguments.contains("\"a\""))

        // A model that emits malformed JSON still shows the user something.
        let broken = ToolRun(name: "t", arguments: "{not json", result: "ok")
        XCTAssertEqual(broken.formattedArguments, "{not json")
    }
}

// MARK: - Router unit tests

final class AgentRouterTests: XCTestCase {

    private let agents = [
        Agent(name: "Researcher", tagline: "Digs deep", systemPrompt: "r"),
        Agent(name: "Coder", tagline: "Writes code", systemPrompt: "c"),
        Agent(name: "Writer", tagline: "Polishes prose", systemPrompt: "w")
    ]

    func testExactMatch() {
        XCTAssertEqual(AgentRouter.match(reply: "Coder", agents: agents)?.name, "Coder")
    }

    func testCaseInsensitiveAndWhitespace() {
        XCTAssertEqual(AgentRouter.match(reply: "  cOdEr\n", agents: agents)?.name, "Coder")
    }

    func testThinkingModelPicksLastMentionedName() {
        // Reasoning models weigh several candidates before naming the final
        // choice at the end — the last mention wins.
        let reply = "<think>Maybe Researcher fits? But the ask is code, so Coder.</think>Coder"
        XCTAssertEqual(AgentRouter.match(reply: reply, agents: agents)?.name, "Coder")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(AgentRouter.match(reply: "Astronaut", agents: agents))
        XCTAssertNil(AgentRouter.match(reply: "", agents: agents))
    }

    func testRoutingPromptListsEveryAgent() {
        let prompt = AgentRouter.routingPrompt(question: "help me", agents: agents)
        for agent in agents {
            XCTAssertTrue(prompt.contains(agent.name))
        }
        XCTAssertTrue(prompt.contains("help me"))
    }
}

// MARK: - Think-block stripping

final class ThinkBlockStrippingTests: XCTestCase {

    func testPlainTextPassesThrough() {
        XCTAssertEqual("Just an answer.".strippingThinkBlocks, "Just an answer.")
    }

    func testEmptyThinkBlockIsRemoved() {
        // The exact shape qwen3 emits when it skips reasoning — this hidden
        // prefix was what inflated every fresh chat's token count.
        XCTAssertEqual("<think>\n\n</think>\n\nHello!".strippingThinkBlocks, "Hello!")
    }

    func testThinkBlockWithContentIsRemoved() {
        XCTAssertEqual("<think>step 1, step 2</think>The result is 42.".strippingThinkBlocks,
                       "The result is 42.")
    }

    func testMultipleThinkBlocksAreRemoved() {
        XCTAssertEqual("<think>a</think>First.<think>b</think> Second.".strippingThinkBlocks,
                       "First. Second.")
    }

    func testUnterminatedThinkBlockDropsTail() {
        XCTAssertEqual("Answer so far <think>half a thought".strippingThinkBlocks,
                       "Answer so far")
    }
}

// MARK: - Backend usage decoding

final class BackendUsageDecodingTests: XCTestCase {

    func testOllamaFinalChunkYieldsRealCounts() throws {
        // The shape Ollama actually sends on its last chunk. These fields were
        // previously dropped, so every tok/s figure came from a heuristic.
        let json = #"{"message":{"content":""},"done":true,"prompt_eval_count":26,"eval_count":298,"eval_duration":4883583000}"#
        let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: json.data(using: .utf8)!)

        let usage = try XCTUnwrap(chunk.usage)
        XCTAssertEqual(usage.promptTokens, 26)
        XCTAssertEqual(usage.completionTokens, 298)
        // eval_duration is nanoseconds — ~4.88s.
        XCTAssertEqual(usage.generationSeconds ?? 0, 4.883583, accuracy: 0.0001)
    }

    func testOllamaMidStreamChunkReportsNoUsage() throws {
        let json = #"{"message":{"content":"hi"},"done":false}"#
        let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: json.data(using: .utf8)!)
        XCTAssertNil(chunk.usage, "only the final chunk carries counts")
    }

    func testOpenAIUsageOnlyChunkDecodesWithoutChoices() throws {
        // A usage-only final chunk may omit `choices` entirely; decoding must
        // survive it or the token counts are lost.
        let json = #"{"id":"x","usage":{"prompt_tokens":11,"completion_tokens":22}}"#
        let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: json.data(using: .utf8)!)

        let usage = try XCTUnwrap(chunk.usage?.asUsage)
        XCTAssertEqual(usage.promptTokens, 11)
        XCTAssertEqual(usage.completionTokens, 22)
    }
}

// MARK: - OpenAI streaming tool-call reassembly

final class OpenAIToolCallAssemblerTests: XCTestCase {

    /// Decodes one SSE chunk's `delta.tool_calls` the way the stream loop does.
    private func fragments(_ json: String) -> [OpenAIStreamChunk.OpenAIToolCall] {
        let data = json.data(using: .utf8)!
        let chunk = try! JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
        return chunk.choices?.first?.delta.toolCalls ?? []
    }

    func testReassemblesFragmentedNameAndArguments() {
        // The real failure mode: name only in the first fragment, arguments
        // dribbled across several. The old code yielded each fragment as a
        // finished call (empty names, truncated JSON).
        var assembler = OpenAIToolCallAssembler()
        assembler.ingest(fragments(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":""}}]}}]}"#))
        assembler.ingest(fragments(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"loc"}}]}}]}"#))
        assembler.ingest(fragments(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ation\":\"NYC\"}"}}]}}]}"#))

        let calls = assembler.assembled()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, "call_1")
        XCTAssertEqual(calls.first?.name, "get_weather")
        XCTAssertEqual(calls.first?.arguments, "{\"location\":\"NYC\"}")
    }

    func testParallelToolCallsKeyedByIndex() {
        var assembler = OpenAIToolCallAssembler()
        assembler.ingest(fragments(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"first","arguments":"{}"}},{"index":1,"id":"b","function":{"name":"second","arguments":"{}"}}]}}]}"#))

        let calls = assembler.assembled()
        XCTAssertEqual(calls.map(\.name), ["first", "second"])
        XCTAssertEqual(calls.map(\.id), ["a", "b"])
    }

    func testNamelessFragmentsAreDropped() {
        var assembler = OpenAIToolCallAssembler()
        assembler.ingest(fragments(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}"#))
        XCTAssertTrue(assembler.assembled().isEmpty, "a fragment that never carried a name isn't a usable call")
    }

    func testEmptyArgumentsDefaultToJSONObject() {
        var assembler = OpenAIToolCallAssembler()
        assembler.ingest(fragments(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"noargs"}}]}}]}"#))
        XCTAssertEqual(assembler.assembled().first?.arguments, "{}")
    }
}
