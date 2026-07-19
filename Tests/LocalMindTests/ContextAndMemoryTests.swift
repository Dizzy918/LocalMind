//
//  ContextAndMemoryTests.swift
//  LocalMindTests
//
//  Tests for token-budget context selection, reasoning extraction,
//  cross-conversation memory, and the new persistence fields.
//

import XCTest
@testable import LocalMind

// MARK: - Context selection

final class ContextSelectionTests: XCTestCase {

    private func message(_ role: MessageRole, _ content: String) -> ChatMessage {
        ChatMessage(role: role, content: content)
    }

    func testRespectsMessageCap() {
        let messages = (0..<20).map { message($0 % 2 == 0 ? .user : .assistant, "message \($0)") }
        let result = ChatGenerationService.selectContext(messages: messages, maxMessages: 5, tokenBudget: 100_000)
        XCTAssertEqual(result.included.count, 5)
        XCTAssertEqual(result.excludedCount, 15)
        XCTAssertEqual(result.included.last?.content, "message 19", "must keep the newest messages")
    }

    func testTokenBudgetTrimsBelowMessageCap() {
        // Three huge messages and one small newest — a small budget should
        // keep only the tail.
        let big = String(repeating: "lorem ipsum dolor sit amet ", count: 200)
        let messages = [
            message(.user, big),
            message(.assistant, big),
            message(.user, big),
            message(.user, "short question")
        ]
        let result = ChatGenerationService.selectContext(messages: messages, maxMessages: 10, tokenBudget: 50)
        XCTAssertEqual(result.included.count, 1)
        XCTAssertEqual(result.included.first?.content, "short question")
        XCTAssertEqual(result.excludedCount, 3)
    }

    func testAlwaysIncludesNewestEvenOverBudget() {
        let huge = String(repeating: "word ", count: 5000)
        let result = ChatGenerationService.selectContext(
            messages: [ChatMessage(role: .user, content: huge)],
            maxMessages: 10,
            tokenBudget: 10
        )
        XCTAssertEqual(result.included.count, 1, "sending nothing is worse than backend-side truncation")
        XCTAssertEqual(result.excludedCount, 0)
    }

    func testEverythingFitsNothingExcluded() {
        let messages = (0..<4).map { ChatMessage(role: .user, content: "msg \($0)") }
        let result = ChatGenerationService.selectContext(messages: messages, maxMessages: 10, tokenBudget: 1000)
        XCTAssertEqual(result.included.count, 4)
        XCTAssertEqual(result.excludedCount, 0)
    }
}

// MARK: - Reasoning extraction

final class ReasoningSeparationTests: XCTestCase {

    func testSeparatesReasoningFromAnswer() {
        let (reasoning, answer) = "<think>step 1</think>The answer.".separatingThinkBlocks
        XCTAssertEqual(reasoning, "step 1")
        XCTAssertEqual(answer, "The answer.")
    }

    func testNoThinkBlockMeansNilReasoning() {
        let (reasoning, answer) = "Plain answer.".separatingThinkBlocks
        XCTAssertNil(reasoning)
        XCTAssertEqual(answer, "Plain answer.")
    }

    func testEmptyThinkBlockMeansNilReasoning() {
        let (reasoning, answer) = "<think>\n\n</think>\n\nHi!".separatingThinkBlocks
        XCTAssertNil(reasoning, "whitespace-only reasoning should not produce a disclosure")
        XCTAssertEqual(answer, "Hi!")
    }

    func testUnterminatedBlockIsLiveThinkingState() {
        // Mid-stream: the model is still inside its think block.
        let (reasoning, answer) = "<think>weighing the options".separatingThinkBlocks
        XCTAssertEqual(reasoning, "weighing the options")
        XCTAssertEqual(answer, "")
    }

    func testMultipleBlocksJoinReasoning() {
        let (reasoning, answer) = "<think>a</think>First. <think>b</think>Second.".separatingThinkBlocks
        XCTAssertEqual(reasoning, "a\n\nb")
        XCTAssertEqual(answer, "First. Second.")
    }
}

// MARK: - Chat memory

@MainActor
final class ChatMemoryStoreTests: XCTestCase {

    var store: ChatMemoryStore!
    var fileURL: URL!
    private var savedFlag: Bool!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindTests-memory-\(UUID().uuidString).json")
        store = ChatMemoryStore(fileURLOverride: fileURL)
        savedFlag = UserDefaults.standard.bool(forKey: "rememberPastChats")
        UserDefaults.standard.set(true, forKey: "rememberPastChats")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedFlag, forKey: "rememberPastChats")
        try? FileManager.default.removeItem(at: fileURL)
        store = nil
        super.tearDown()
    }

    func testExchangePairing() {
        let messages = [
            ChatMessage(role: .user, content: "How do I sort in Swift?"),
            ChatMessage(role: .assistant, content: "Use sorted()."),
            ChatMessage(role: .user, content: "And in place?"),
            ChatMessage(role: .assistant, content: "Use sort().")
        ]
        let exchanges = ChatMemoryStore.exchanges(from: messages)
        XCTAssertEqual(exchanges.count, 2)
        XCTAssertTrue(exchanges[0].contains("How do I sort in Swift?"))
        XCTAssertTrue(exchanges[0].contains("Use sorted()."))
    }

    func testIndexAndRecallAcrossConversations() async throws {
        guard EmbeddingService.isAvailable else {
            throw XCTSkip("On-device embeddings unavailable on this machine")
        }

        let swiftChat = Conversation(
            title: "Swift Sorting",
            messages: [
                ChatMessage(role: .user, content: "How do I sort an array of numbers in Swift?"),
                ChatMessage(role: .assistant, content: "Call sorted() for a new array or sort() to sort in place.")
            ]
        )
        let cookingChat = Conversation(
            title: "Dinner Ideas",
            messages: [
                ChatMessage(role: .user, content: "What should I cook for dinner tonight?"),
                ChatMessage(role: .assistant, content: "How about a simple pasta with garlic and olive oil?")
            ]
        )
        await store.indexConversation(swiftChat)
        await store.indexConversation(cookingChat)
        XCTAssertEqual(store.entryCount, 2)

        // Re-indexing without new exchanges must not duplicate.
        await store.indexConversation(swiftChat)
        XCTAssertEqual(store.entryCount, 2)

        // Recall from a *different* conversation should surface the Swift
        // exchange for a Swift question, and exclude the asking conversation.
        let asking = UUID()
        let hits = await store.recall("sorting arrays in Swift code", excluding: asking, topK: 1)
        XCTAssertEqual(hits.first?.title, "Swift Sorting")

        // The source conversation itself must never be recalled.
        let selfHits = await store.recall("sorting arrays in Swift code", excluding: swiftChat.id, topK: 5)
        XCTAssertFalse(selfHits.contains { $0.title == "Swift Sorting" })
    }

    func testForgetRemovesConversation() async throws {
        guard EmbeddingService.isAvailable else {
            throw XCTSkip("On-device embeddings unavailable on this machine")
        }
        let conversation = Conversation(
            title: "Temp",
            messages: [
                ChatMessage(role: .user, content: "Remember this thing"),
                ChatMessage(role: .assistant, content: "Noted.")
            ]
        )
        await store.indexConversation(conversation)
        XCTAssertGreaterThan(store.entryCount, 0)

        store.forget(conversationID: conversation.id)
        XCTAssertEqual(store.entryCount, 0)
    }

    func testDisabledFeatureIndexesNothing() async {
        UserDefaults.standard.set(false, forKey: "rememberPastChats")
        let conversation = Conversation(
            title: "Off",
            messages: [ChatMessage(role: .user, content: "hi"), ChatMessage(role: .assistant, content: "hey")]
        )
        await store.indexConversation(conversation)
        XCTAssertEqual(store.entryCount, 0)
    }
}

// MARK: - New persistence fields

final class NewFieldPersistenceTests: XCTestCase {

    func testConversationSummaryFieldsRoundtrip() throws {
        var conversation = Conversation(title: "Long chat")
        conversation.messages = [ChatMessage(role: .user, content: "hi")]
        conversation.contextSummary = "They discussed sorting."
        conversation.summarizedMessageCount = 12

        let decoded = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(conversation)
        )
        XCTAssertEqual(decoded.contextSummary, "They discussed sorting.")
        XCTAssertEqual(decoded.summarizedMessageCount, 12)
    }

    func testLegacyConversationDefaultsSummaryFields() throws {
        var conversation = Conversation(title: "Legacy")
        conversation.messages = [ChatMessage(role: .user, content: "hi")]
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(conversation)
        ) as! [String: Any]
        object.removeValue(forKey: "contextSummary")
        object.removeValue(forKey: "summarizedMessageCount")
        let decoded = try JSONDecoder().decode(
            Conversation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.contextSummary)
        XCTAssertEqual(decoded.summarizedMessageCount, 0)
    }

    func testLegacyKnowledgeDocumentDecodesWithoutNewFields() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "name": "old.pdf", "addedAt": 700000000, "chunkCount": 3}
        """
        let decoded = try JSONDecoder().decode(KnowledgeDocument.self, from: Data(json.utf8))
        XCTAssertNil(decoded.collection)
        XCTAssertNil(decoded.sourcePath)
        XCTAssertNil(decoded.fileModifiedAt)
    }

    func testAgentKnowledgeCollectionsRoundtrip() throws {
        let agent = Agent(name: "Scoped", systemPrompt: "s", knowledgeCollections: ["Papers", "API docs"])
        let decoded = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent))
        XCTAssertEqual(decoded.knowledgeCollections, ["Papers", "API docs"])
    }

    func testMessagePerfAndReasoningRoundtrip() throws {
        var message = ChatMessage(role: .assistant, content: "Answer")
        message.reasoning = "chain of thought"
        message.generationSeconds = 4.2
        message.tokensPerSecond = 38.5

        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.reasoning, "chain of thought")
        XCTAssertEqual(decoded.generationSeconds, 4.2)
        XCTAssertEqual(decoded.tokensPerSecond, 38.5)
    }

    func testOllamaPullProgressFraction() {
        XCTAssertEqual(OllamaPullProgress(status: "pulling", completed: 500, total: 1000).fraction, 0.5)
        XCTAssertNil(OllamaPullProgress(status: "verifying", completed: nil, total: nil).fraction)
        XCTAssertNil(OllamaPullProgress(status: "odd", completed: 1, total: 0).fraction)
    }
}

// MARK: - Prompt snippets & MCP catalog

final class PromptSnippetAndCatalogTests: XCTestCase {

    var dataStore: DataStore!
    var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        dataStore = DataStore(baseDirectoryOverride: testDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        dataStore = nil
        super.tearDown()
    }

    func testSnippetSaveUpdateDeletePersist() {
        var snippet = PromptSnippet(title: "Email intro", text: "Write a professional email about")
        dataStore.savePromptSnippet(snippet)
        XCTAssertEqual(dataStore.promptSnippets.count, 1)

        snippet.text = "Write a friendly email about"
        dataStore.savePromptSnippet(snippet)
        XCTAssertEqual(dataStore.promptSnippets.count, 1, "same ID must update, not duplicate")
        XCTAssertEqual(dataStore.promptSnippets.first?.text, "Write a friendly email about")

        // Survives a store reload.
        let reloaded = DataStore(baseDirectoryOverride: testDir)
        XCTAssertEqual(reloaded.promptSnippets.first?.title, "Email intro")

        dataStore.deletePromptSnippet(snippet)
        XCTAssertTrue(dataStore.promptSnippets.isEmpty)
        let reloadedAfterDelete = DataStore(baseDirectoryOverride: testDir)
        XCTAssertTrue(reloadedAfterDelete.promptSnippets.isEmpty)
    }

    func testCatalogEntriesAreWellFormed() {
        let entries = MCPCatalog.all
        XCTAssertGreaterThanOrEqual(entries.count, 16)
        // IDs and display names must be unique — they key the install UI.
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertEqual(Set(entries.map(\.name)).count, entries.count)
        for entry in entries {
            XCTAssertFalse(entry.description.isEmpty, "\(entry.id) needs a description")
            if case let .stdio(command, args, _) = entry.template.transport {
                XCTAssertFalse(command.isEmpty)
                XCTAssertFalse(args.isEmpty, "\(entry.id) should launch a package")
            } else {
                XCTFail("\(entry.id): catalog entries should be stdio-launched")
            }
        }
    }
}
