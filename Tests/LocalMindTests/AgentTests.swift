//
//  AgentTests.swift
//  LocalMindTests
//
//  Tests for the Agent model, its persistence in DataStore, and the
//  conversation ↔ agent assignment.
//

import XCTest
@testable import LocalMind

final class AgentTests: XCTestCase {

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

    // MARK: - Codable

    func testAgentCodableRoundtrip() throws {
        let agent = Agent(
            name: "Coder",
            emoji: "💻",
            tagline: "Code-first answers",
            systemPrompt: "You are an expert software engineer.",
            modelID: "qwen2.5-coder:7b",
            temperature: 0.2,
            allowTools: false,
            useKnowledgeBase: true
        )

        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)

        XCTAssertEqual(decoded.id, agent.id)
        XCTAssertEqual(decoded.name, "Coder")
        XCTAssertEqual(decoded.emoji, "💻")
        XCTAssertEqual(decoded.tagline, "Code-first answers")
        XCTAssertEqual(decoded.modelID, "qwen2.5-coder:7b")
        XCTAssertEqual(decoded.temperature, 0.2)
        XCTAssertFalse(decoded.allowTools)
        XCTAssertTrue(decoded.useKnowledgeBase)
    }

    func testAgentDecodesMinimalJSONWithDefaults() throws {
        // A file written by an older (or future, field-dropping) build must
        // still decode, with sensible defaults for everything missing.
        let json = """
        {"id": "\(UUID().uuidString)", "name": "Bare", "systemPrompt": "Hi."}
        """
        let decoded = try JSONDecoder().decode(Agent.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.name, "Bare")
        XCTAssertEqual(decoded.emoji, "🤖")
        XCTAssertEqual(decoded.tagline, "")
        XCTAssertNil(decoded.modelID)
        XCTAssertNil(decoded.temperature)
        XCTAssertTrue(decoded.allowTools)
        XCTAssertFalse(decoded.useKnowledgeBase)
    }

    // MARK: - DataStore persistence

    func testSaveAndDeleteAgent() {
        let agent = Agent(name: "Writer", systemPrompt: "You write well.")
        dataStore.saveAgent(agent)
        XCTAssertTrue(dataStore.agents.contains { $0.id == agent.id })

        dataStore.deleteAgent(agent)
        XCTAssertFalse(dataStore.agents.contains { $0.id == agent.id })
    }

    func testSaveUpdatesExistingAgentInsteadOfDuplicating() {
        var agent = Agent(name: "Researcher", systemPrompt: "Research things.")
        dataStore.saveAgent(agent)

        agent.name = "Deep Researcher"
        dataStore.saveAgent(agent)

        let matches = dataStore.agents.filter { $0.id == agent.id }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.name, "Deep Researcher")
    }

    func testAgentsPersistAcrossStoreInstances() {
        let agent = Agent(name: "Critic", emoji: "🧐", systemPrompt: "Find flaws.")
        dataStore.saveAgent(agent)

        let reloaded = DataStore(baseDirectoryOverride: testDir)
        let stored = reloaded.agents.first { $0.id == agent.id }
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.name, "Critic")
        XCTAssertEqual(stored?.emoji, "🧐")
    }

    func testAgentLookupByID() {
        let agent = Agent(name: "Helper", systemPrompt: "Help.")
        dataStore.saveAgent(agent)

        XCTAssertEqual(dataStore.agent(withID: agent.id)?.name, "Helper")
        XCTAssertNil(dataStore.agent(withID: UUID()))
        XCTAssertNil(dataStore.agent(withID: nil))
    }

    // MARK: - Conversation assignment

    func testConversationAgentIDRoundtrip() throws {
        let agentID = UUID()
        let conversation = Conversation(
            title: "With agent",
            messages: [ChatMessage(role: .user, content: "Hi")],
            agentID: agentID
        )

        let data = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(decoded.agentID, agentID)
    }

    func testOldConversationWithoutAgentIDDecodesAsNil() throws {
        // Simulates a conversation file from before agents existed.
        var conversation = Conversation(title: "Legacy")
        conversation.messages.append(ChatMessage(role: .user, content: "Hi"))
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(conversation)
        ) as! [String: Any]
        object.removeValue(forKey: "agentID")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Conversation.self, from: stripped)
        XCTAssertNil(decoded.agentID)
    }

    // MARK: - Cross-backend & tool allowlist fields

    func testBackendAndAllowlistRoundtrip() throws {
        let agent = Agent(
            name: "Pinned",
            systemPrompt: "p",
            backend: .appleFoundationModels,
            modelID: "some-model",
            allowedToolIDs: ["search_web", "read_file"]
        )

        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)

        XCTAssertEqual(decoded.backend, .appleFoundationModels)
        XCTAssertEqual(decoded.allowedToolIDs, ["search_web", "read_file"])
    }

    func testUnknownBackendStringDecodesAsNil() throws {
        // A file written by a future build with a backend this build doesn't
        // know must not fail the whole agent — it degrades to "current".
        let json = """
        {"id": "\(UUID().uuidString)", "name": "Future", "systemPrompt": "f", "backend": "Quantum Cloud"}
        """
        let decoded = try JSONDecoder().decode(Agent.self, from: Data(json.utf8))
        XCTAssertNil(decoded.backend)
        XCTAssertEqual(decoded.name, "Future")
    }

    // MARK: - Import / Export

    func testExportImportRoundtrip() throws {
        dataStore.saveAgent(Agent(name: "One", emoji: "1️⃣", systemPrompt: "a", temperature: 0.3))
        dataStore.saveAgent(Agent(name: "Two", emoji: "2️⃣", systemPrompt: "b", allowedToolIDs: ["t1"]))

        let data = try XCTUnwrap(dataStore.exportAgentsData())

        // Import into a fresh store.
        let otherDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherDir) }
        let otherStore = DataStore(baseDirectoryOverride: otherDir)

        let imported = otherStore.importAgents(from: data)
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(otherStore.agents.count, 2)
        XCTAssertEqual(otherStore.agents.first { $0.name == "One" }?.temperature, 0.3)
        XCTAssertEqual(otherStore.agents.first { $0.name == "Two" }?.allowedToolIDs, ["t1"])
    }

    func testImportUpdatesExistingAgentByID() throws {
        var agent = Agent(name: "Original", systemPrompt: "v1")
        dataStore.saveAgent(agent)

        agent.name = "Renamed"
        agent.systemPrompt = "v2"
        let data = try JSONEncoder().encode([agent])

        let imported = dataStore.importAgents(from: data)
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(dataStore.agents.count, 1, "same ID must update, not duplicate")
        XCTAssertEqual(dataStore.agents.first?.name, "Renamed")
        XCTAssertEqual(dataStore.agents.first?.systemPrompt, "v2")
    }

    func testImportGarbageReturnsZero() {
        XCTAssertEqual(dataStore.importAgents(from: Data("not json".utf8)), 0)
        XCTAssertEqual(dataStore.importAgents(from: Data("{\"foo\": 1}".utf8)), 0)
        XCTAssertTrue(dataStore.agents.isEmpty)
    }

    // MARK: - Message attribution

    func testChatMessageAttributionRoundtrip() throws {
        var message = ChatMessage(role: .assistant, content: "Answer")
        message.agentName = "Coder"
        message.agentEmoji = "💻"
        message.modelUsed = "qwen3:8b"

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.agentName, "Coder")
        XCTAssertEqual(decoded.agentEmoji, "💻")
        XCTAssertEqual(decoded.modelUsed, "qwen3:8b")
    }

    func testLegacyMessageWithoutAttributionDecodesAsNil() throws {
        let message = ChatMessage(role: .assistant, content: "Old answer")
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(message)
        ) as! [String: Any]
        object.removeValue(forKey: "agentName")
        object.removeValue(forKey: "agentEmoji")
        object.removeValue(forKey: "modelUsed")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ChatMessage.self, from: stripped)
        XCTAssertNil(decoded.agentName)
        XCTAssertNil(decoded.modelUsed)
    }

    // MARK: - Templates

    func testStarterTemplatesMintFreshIDs() {
        let first = Agent.starterTemplates()
        let second = Agent.starterTemplates()
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
    }
}
