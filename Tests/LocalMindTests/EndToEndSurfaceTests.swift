//
//  EndToEndSurfaceTests.swift
//  LocalMindTests
//
//  Whole-feature paths, run for real rather than against mocks: the Shortcuts
//  intents actually performed, the knowledge base built from real files on
//  disk, and the multi-agent surfaces driven by a live model.
//
//  These are the surfaces that had only ever been checked a piece at a time.
//  Every previous swap of a mock for something real in this project turned up a
//  defect that the unit suite was structurally unable to see, so the point here
//  is to run each feature the way a user does — end to end, with its real
//  inputs — and assert on what comes out the far side.
//
//  Anything needing a model skips cleanly when Ollama isn't running.
//

import AppIntents
import XCTest
@testable import LocalMind

// MARK: - Shortcuts / App Intents

/// Executes the intents' own `perform()` bodies.
///
/// The system's Shortcuts runtime can't be driven from a test — the `shortcuts`
/// CLI only runs shortcuts a user already created — but that layer is Apple's.
/// What's ours is the intent implementation and the automation path it calls,
/// and that had never been executed at all: registration in the app's
/// `Metadata.appintents` bundle was the only thing ever verified.
@MainActor
final class AppIntentExecutionTests: XCTestCase {

    private var testDir: URL!
    private var dataStore: DataStore!
    private var aiManager: AIServiceManager!
    private var generationService: ChatGenerationService!
    private var profileStore: ProfileStore!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindIntents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        dataStore = DataStore(baseDirectoryOverride: testDir)
        aiManager = AIServiceManager()
        generationService = ChatGenerationService(dataStore: dataStore, aiManager: aiManager)
        profileStore = ProfileStore()
        AppServices.register(
            dataStore: dataStore,
            aiManager: aiManager,
            generationService: generationService,
            profileStore: profileStore
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    private func requireLiveBackend() async throws {
        _ = try await LiveEnvironment.requireOllama(LiveEnvironment.chatModel)
        let ollama = OllamaService(baseURL: LiveEnvironment.ollamaURL, model: LiveEnvironment.chatModel)
        aiManager.setServiceForTesting(ollama)
        try XCTSkipUnless(AppServices.isReadyForAutomation,
                          "automation needs a signed-in profile — skipping")
    }

    func testAskIntentReturnsAnAnswer() async throws {
        try await requireLiveBackend()

        var intent = AskLocalMindIntent()
        intent.prompt = "Reply with a single short sentence saying hello."
        intent.keepInHistory = true

        let result = try await intent.perform()
        let answer = result.value ?? ""

        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "a Shortcut has to receive text back, or it can't feed the rest of a workflow")
        XCTAssertFalse(answer.hasPrefix("⚠️"), "an error must throw, not come back as if it were the answer")
        // The <think> blocks of a reasoning model must never reach a Shortcut.
        XCTAssertFalse(answer.contains("<think>"))
    }

    func testAskIntentRespectsKeepInHistory() async throws {
        try await requireLiveBackend()

        let before = dataStore.conversations.count

        var keep = AskLocalMindIntent()
        keep.prompt = "Say the word: kept"
        keep.keepInHistory = true
        _ = try await keep.perform()
        XCTAssertEqual(dataStore.conversations.count, before + 1, "saved asks appear in history")


        var discard = AskLocalMindIntent()
        discard.prompt = "Say the word: discarded"
        discard.keepInHistory = false
        _ = try await discard.perform()
        XCTAssertEqual(dataStore.conversations.count, before + 1,
                       "an ask marked not-to-keep must leave no conversation behind")
    }

    func testAskIntentUsesTheNamedAgent() async throws {
        try await requireLiveBackend()

        let agent = Agent(
            name: "Pirate",
            emoji: "🏴‍☠️",
            systemPrompt: "You are a pirate. Always answer in pirate speak."
        )
        dataStore.saveAgent(agent)

        var intent = AskLocalMindIntent()
        intent.prompt = "Greet me."
        intent.agentName = "pirate"   // case-insensitive lookup
        intent.keepInHistory = true
        _ = try await intent.perform()

        let stored = dataStore.conversations.first { $0.title.contains("Greet") }
        XCTAssertEqual(stored?.agentID, agent.id, "the named agent must actually answer")
        XCTAssertEqual(stored?.messages.last?.agentName, "Pirate")
    }

    func testAskIntentRejectsAnEmptyPrompt() async throws {
        var intent = AskLocalMindIntent()
        intent.prompt = "   \n "
        intent.keepInHistory = false

        do {
            _ = try await intent.perform()
            XCTFail("an empty prompt should be refused before any generation starts")
        } catch {
            XCTAssertTrue(error is AutomationIntentError)
        }
    }

    func testSearchIntentReturnsLabelledPassages() async throws {
        try XCTSkipUnless(EmbeddingService.isAvailable, "no on-device embeddings — skipping")

        let store = KnowledgeBaseStore.shared
        let indexed = await store.addDocument(
            name: "PolicyNotes.txt",
            text: """
            Expense policy. Meals are reimbursed up to forty euros per day.
            Travel must be booked at least fourteen days in advance.

            Equipment. Laptops are replaced every three years on request.
            """
        )
        try XCTSkipIf(indexed == 0, "document produced no vectors — skipping")
        defer {
            if let doc = store.documents.first(where: { $0.name == "PolicyNotes.txt" }) {
                store.removeDocument(doc)
            }
        }

        var intent = SearchKnowledgeBaseIntent()
        intent.query = "how much for meals"
        intent.limit = 3

        let passages = try await intent.perform().value ?? []
        XCTAssertFalse(passages.isEmpty, "a match in an indexed document must be returned")
        // Each passage carries its source, so the result stands alone once it's
        // pasted into a note or a message.
        XCTAssertTrue(passages.allSatisfy { $0.contains("PolicyNotes.txt:") })
    }

    func testSearchIntentRejectsAnEmptyQuery() async throws {
        var intent = SearchKnowledgeBaseIntent()
        intent.query = ""
        do {
            _ = try await intent.perform()
            XCTFail("an empty query should be refused")
        } catch {
            XCTAssertTrue(error is AutomationIntentError)
        }
    }
}

// MARK: - Knowledge base, from real files

/// Builds the knowledge base the way a user does: real files on disk, through
/// the real importer, then queried for something only those files contain.
@MainActor
final class KnowledgeBaseEndToEndTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindKB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Leave the shared store as we found it.
        let store = KnowledgeBaseStore.shared
        for document in store.documents where document.name.hasPrefix("e2e-") {
            store.removeDocument(document)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTextAndMarkdownFilesExtractAndRetrieve() async throws {
        try XCTSkipUnless(EmbeddingService.isAvailable, "no on-device embeddings — skipping")
        let store = KnowledgeBaseStore.shared

        let notes = try write("e2e-handbook.md", """
        # Engineering Handbook

        ## Incident response
        The on-call rotation hands over every Monday at ten in the morning.
        Sev-1 incidents page the whole platform team immediately.

        ## Deploys
        Production deploys are frozen from the twentieth of December
        until the second of January.
        """)
        let plain = try write("e2e-vendors.txt", """
        Vendor contacts.
        Cloud hosting is billed quarterly by Northwind Systems.
        The support portal password rotates every ninety days.
        """)

        for url in [notes, plain] {
            let extracted = await DocumentImporter.extractTextInBackground(from: url)
            let text = try XCTUnwrap(extracted, "extraction failed for \(url.lastPathComponent)")
            XCTAssertFalse(text.isEmpty)
            let chunks = await store.addDocument(name: url.lastPathComponent, text: text, sourcePath: url.path)
            XCTAssertGreaterThan(chunks, 0, "\(url.lastPathComponent) produced no indexed chunks")
        }

        // A phrase that appears in exactly one document.
        let hits = await store.retrieve("when does the on-call rotation hand over", topK: 4)
        XCTAssertFalse(hits.isEmpty, "the handbook plainly contains this — retrieval must find it")
        XCTAssertTrue(hits.contains { $0.documentName == "e2e-handbook.md" },
                      "got: \(hits.map(\.documentName))")

        // An exact, unusual token — the case the keyword half of hybrid search
        // exists for, since a proper noun embeds weakly.
        let exact = await store.retrieve("Northwind", topK: 4)
        XCTAssertTrue(exact.contains { $0.documentName == "e2e-vendors.txt" },
                      "exact-token search failed; got: \(exact.map(\.documentName))")
    }

    func testReimportingAFileReplacesRatherThanDuplicates() async throws {
        try XCTSkipUnless(EmbeddingService.isAvailable, "no on-device embeddings — skipping")
        let store = KnowledgeBaseStore.shared

        let url = try write("e2e-changing.txt", "The quarterly target is one hundred units.")
        let extracted1 = await DocumentImporter.extractTextInBackground(from: url)
        let text1 = try XCTUnwrap(extracted1)
        _ = await store.addDocument(name: url.lastPathComponent, text: text1, sourcePath: url.path)
        let afterFirst = store.documents.filter { $0.name == "e2e-changing.txt" }.count

        // The file changes on disk and is imported again.
        try "The quarterly target is two hundred units.".write(to: url, atomically: true, encoding: .utf8)
        let extracted2 = await DocumentImporter.extractTextInBackground(from: url)
        let text2 = try XCTUnwrap(extracted2)
        _ = await store.addDocument(name: url.lastPathComponent, text: text2, sourcePath: url.path)

        XCTAssertEqual(store.documents.filter { $0.name == "e2e-changing.txt" }.count, afterFirst,
                       "re-importing the same file must replace it, not add a second copy")

        let hits = await store.retrieve("quarterly target", topK: 3)
        let combined = hits.map(\.text).joined(separator: " ")
        XCTAssertTrue(combined.contains("two hundred"), "the updated content should be what's retrievable")
        XCTAssertFalse(combined.contains("one hundred"), "stale chunks must not survive a re-import")
    }

    func testUnsupportedAndEmptyFilesAreHandled() async throws {
        let binary = folder.appendingPathComponent("e2e-binary.bin")
        try Data([0x00, 0xFF, 0x00, 0xFF, 0x10]).write(to: binary)
        let empty = try write("e2e-empty.txt", "")

        // Neither should crash; both should decline rather than index noise.
        let binaryText = await DocumentImporter.extractTextInBackground(from: binary)
        XCTAssertTrue(binaryText == nil || binaryText?.isEmpty == true
                      || !(binaryText?.contains("\u{0000}") ?? false),
                      "binary content must not be indexed as text")

        let emptyText = await DocumentImporter.extractTextInBackground(from: empty)
        XCTAssertTrue(emptyText == nil || emptyText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
    }

    func testRebuildPreservesDocumentsAndSearchability() async throws {
        try XCTSkipUnless(EmbeddingService.isAvailable, "no on-device embeddings — skipping")
        let store = KnowledgeBaseStore.shared

        let url = try write("e2e-rebuild.txt", """
        Archive notes. The migration to the new billing system completed in March.
        Legacy invoices remain queryable through the reporting console.
        """)
        let extracted = await DocumentImporter.extractTextInBackground(from: url)
        let text = try XCTUnwrap(extracted)
        _ = await store.addDocument(name: url.lastPathComponent, text: text, sourcePath: url.path)

        let before = store.documents.filter { $0.name == "e2e-rebuild.txt" }.count
        let summary = await store.reindexAll()

        XCTAssertGreaterThan(summary.rebuilt, 0, "rebuild should process the indexed documents")
        XCTAssertEqual(store.documents.filter { $0.name == "e2e-rebuild.txt" }.count, before,
                       "a rebuild must not lose documents — that was the old 'clear all' behaviour")

        let hits = await store.retrieve("billing system migration", topK: 3)
        XCTAssertTrue(hits.contains { $0.documentName == "e2e-rebuild.txt" },
                      "documents must still be searchable after a rebuild")
    }
}

// MARK: - Multi-agent surfaces against a live model

/// Pipelines and agent runs, driven by a real backend.
///
/// These paths passed `tools: nil` until recently — a bug that existed
/// precisely because they were never exercised outside the UI.
@MainActor
final class MultiAgentLiveTests: XCTestCase {

    private var testDir: URL!
    private var dataStore: DataStore!
    private var aiManager: AIServiceManager!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindAgents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        dataStore = DataStore(baseDirectoryOverride: testDir)
        aiManager = AIServiceManager()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    private func liveService() async throws -> OllamaService {
        _ = try await LiveEnvironment.requireOllama(LiveEnvironment.chatModel)
        let ollama = OllamaService(baseURL: LiveEnvironment.ollamaURL, model: LiveEnvironment.chatModel)
        aiManager.setServiceForTesting(ollama)
        return ollama
    }

    func testAgentPersonaChangesTheAnswer() async throws {
        let service = try await liveService()

        // Two personas, same question, temperature 0 — the system prompt is the
        // only difference, so the outputs should not be identical.
        func answer(systemPrompt: String) async throws -> String {
            let outcome = try await aiManager.streamChatWithTools(
                service: service,
                messages: [ChatMessage(role: .user, content: "Describe the sea in one sentence.")],
                systemPrompt: systemPrompt,
                modelOverride: LiveEnvironment.chatModel,
                parameters: AIParameters(temperature: 0),
                tools: nil,
                onDelta: { _ in }
            )
            return outcome.text.strippingThinkBlocks
        }

        let pirate = try await answer(systemPrompt: "You are a pirate. Answer only in pirate speak.")
        let scientist = try await answer(systemPrompt: "You are a marine biologist. Answer precisely and technically.")

        XCTAssertFalse(pirate.isEmpty)
        XCTAssertFalse(scientist.isEmpty)
        XCTAssertNotEqual(pirate, scientist, "the agent's system prompt must actually reach the model")
    }

    func testPipelineStepsChainTheirOutput() async throws {
        let service = try await liveService()

        // Step one produces something specific; step two must transform *that*
        // rather than answering the original request afresh.
        let first = try await aiManager.streamChatWithTools(
            service: service,
            messages: [ChatMessage(role: .user, content: "List exactly three fruits, comma separated. No other words.")],
            systemPrompt: "You follow formatting instructions exactly.",
            modelOverride: LiveEnvironment.chatModel,
            parameters: AIParameters(temperature: 0),
            tools: nil,
            onDelta: { _ in }
        )
        let listed = first.text.strippingThinkBlocks
        XCTAssertFalse(listed.isEmpty)

        let second = try await aiManager.streamChatWithTools(
            service: service,
            messages: [ChatMessage(role: .user, content: """
            Output from the previous step:
            \(listed)

            Your task: count how many items the previous step listed. Reply with just the number.
            """)],
            systemPrompt: "You are one stage of a multi-step workflow.",
            modelOverride: LiveEnvironment.chatModel,
            parameters: AIParameters(temperature: 0),
            tools: nil,
            onDelta: { _ in }
        )
        let counted = second.text.strippingThinkBlocks

        XCTAssertFalse(counted.isEmpty, "a pipeline step must produce output for the next one")
        XCTAssertTrue(counted.contains("3") || counted.lowercased().contains("three"),
                      "step two should have read step one's output; got: \(counted.prefix(120))")
    }

    func testAgentsRunConcurrentlyWithoutInterfering() async throws {
        let service = try await liveService()

        // The arena fans out; each run must come back with its own answer
        // rather than sharing or clobbering state.
        async let alpha = aiManager.streamChatWithTools(
            service: service,
            messages: [ChatMessage(role: .user, content: "Reply with exactly: ALPHA")],
            systemPrompt: "Reply with the single word requested.",
            modelOverride: LiveEnvironment.chatModel,
            parameters: AIParameters(temperature: 0), tools: nil, onDelta: { _ in }
        )
        async let beta = aiManager.streamChatWithTools(
            service: service,
            messages: [ChatMessage(role: .user, content: "Reply with exactly: BETA")],
            systemPrompt: "Reply with the single word requested.",
            modelOverride: LiveEnvironment.chatModel,
            parameters: AIParameters(temperature: 0), tools: nil, onDelta: { _ in }
        )

        let results = try await [alpha.text.strippingThinkBlocks, beta.text.strippingThinkBlocks]
        XCTAssertTrue(results[0].uppercased().contains("ALPHA"), "got: \(results[0].prefix(80))")
        XCTAssertTrue(results[1].uppercased().contains("BETA"), "got: \(results[1].prefix(80))")
    }
}

// MARK: - Backend health-check behaviour

/// The health poll used to discard a working connection.
///
/// Local model servers saturate the CPU while generating, so a health request
/// issued mid-generation gets starved. A single missed probe then tore the
/// connection down — `currentService` became nil and the very next request
/// failed with "No AI backend available" while the model was still running.
/// Found by running two Shortcuts asks back to back against a real Ollama:
/// the first succeeded, the second failed, every time.
@MainActor
final class BackendHealthTests: XCTestCase {

    func testConnectionSurvivesBackToBackGenerations() async throws {
        _ = try await LiveEnvironment.requireOllama(LiveEnvironment.chatModel)

        let manager = AIServiceManager()
        let ollama = OllamaService(baseURL: LiveEnvironment.ollamaURL, model: LiveEnvironment.chatModel)
        manager.setServiceForTesting(ollama)

        // Three short generations spanning well past the 3-second poll
        // interval, which is when the old code lost the backend.
        for index in 1...3 {
            XCTAssertTrue(manager.currentService != nil,
                          "backend disappeared before generation \(index)")
            let outcome = try await manager.streamChatWithTools(
                service: ollama,
                messages: [ChatMessage(role: .user, content: "Reply with the number \(index).")],
                systemPrompt: "Answer with one word.",
                modelOverride: LiveEnvironment.chatModel,
                parameters: AIParameters(temperature: 0),
                tools: nil,
                onDelta: { _ in }
            )
            XCTAssertFalse(outcome.text.strippingThinkBlocks.isEmpty)
            try? await Task.sleep(for: .milliseconds(1_500))
        }

        XCTAssertNotNil(manager.currentService,
                        "the backend must still be connected after several generations")
        XCTAssertNotEqual(manager.currentBackend, AIBackend.none)
    }

    func testIdleConnectionIsNotDroppedByASinglePoll() async throws {
        _ = try await LiveEnvironment.requireOllama(LiveEnvironment.chatModel)

        let manager = AIServiceManager()
        manager.setServiceForTesting(
            OllamaService(baseURL: LiveEnvironment.ollamaURL, model: LiveEnvironment.chatModel)
        )

        // Sit idle across several poll intervals with nothing in flight.
        try? await Task.sleep(for: .seconds(8))

        XCTAssertNotNil(manager.currentService, "an idle, healthy backend must stay connected")
    }
}
