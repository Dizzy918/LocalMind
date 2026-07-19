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
            systemPrompt: systemPrompt,
            modelOverride: modelOverride,
            temperature: parameters?.temperature,
            toolNames: tools.map { $0.map(\.name) }
        ))
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
