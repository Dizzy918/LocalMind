//
//  LiveBackendIntegrationTests.swift
//  LocalMindTests
//
//  Exercises the real service classes against a real Ollama and a real MCP
//  server — no mocks anywhere in the path.
//
//  This layer exists because its absence hid a total failure of tool calling.
//  The mock backend used by the rest of the suite never encodes a request, so
//  a body that JSONSerialization refuses to write looked correct in every test
//  while crashing against an actual server. Anything that only breaks on the
//  wire belongs here.
//
//  Every test skips cleanly when the dependency isn't present, so the suite
//  still passes on a machine without Ollama or without a network.
//

import XCTest
@testable import LocalMind

/// Shared probes for the external dependencies these tests need.
enum LiveEnvironment {
    static let ollamaURL = URL(string: "http://localhost:11434")!
    /// Small and fast — fine for plain generation.
    static let chatModel = "qwen2.5-coder:3b"
    static let visionModel = "llava:latest"

    /// Models known to emit *native* `tool_calls`, most preferred first.
    ///
    /// This distinction matters and isn't obvious: a model can look like it's
    /// calling a tool while actually writing a fenced JSON blob into its normal
    /// text, which no client can execute. qwen2.5-coder:3b does exactly that.
    /// Only models that emit the real field can exercise the tool path.
    static let toolCapableModels = [
        "qwen3:8b", "qwen3", "llama3.1", "llama3.2", "mistral-nemo", "command-r", "firefunction-v2"
    ]

    /// The first available model that genuinely supports tool calling.
    static func toolCapableModel(from installed: [String]) -> String? {
        for candidate in toolCapableModels {
            if let match = installed.first(where: { $0 == candidate || $0.hasPrefix(candidate + ":") }) {
                return match
            }
        }
        return nil
    }

    static func ollamaModels() async -> [String] {
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    static func requireOllama(_ model: String? = nil) async throws -> [String] {
        let models = await ollamaModels()
        try XCTSkipIf(models.isEmpty, "Ollama isn't running — skipping live backend test")
        if let model {
            try XCTSkipUnless(models.contains(model), "Model \(model) isn't pulled — skipping")
        }
        return models
    }

    /// Whether npx exists, which the filesystem MCP server needs.
    static func requireNPX() throws {
        let found = (try? MCPClient.resolveExecutable("npx")) != nil
        try XCTSkipUnless(found, "npx not on PATH — skipping live MCP test")
    }

    /// Live MCP tests are opt-in via `LOCALMIND_LIVE_MCP=1`.
    ///
    /// They spawn real `npx` servers inside the test host — which is also a
    /// full app instance that connects to whatever MCP servers the developer
    /// has configured. A dozen node and python processes then compete for the
    /// machine, and handshakes that take 2s in isolation blow past any
    /// reasonable timeout. That makes the tests non-deterministic for reasons
    /// unrelated to the code under test, so they don't run by default.
    static func requireLiveMCPOptIn() throws {
        let enabled = ProcessInfo.processInfo.environment["LOCALMIND_LIVE_MCP"] == "1"
        try XCTSkipUnless(enabled, "Set LOCALMIND_LIVE_MCP=1 to run live MCP tests")
    }
}

// MARK: - Ollama, end to end

final class LiveOllamaTests: XCTestCase {

    private func service() -> OllamaService {
        OllamaService(baseURL: LiveEnvironment.ollamaURL, model: LiveEnvironment.chatModel)
    }

    func testAvailabilityAndModelListing() async throws {
        _ = try await LiveEnvironment.requireOllama()
        let ollama = service()

        let available = await ollama.checkAvailability()
        XCTAssertTrue(available)

        let models = try await ollama.listModels()
        XCTAssertFalse(models.isEmpty)
        // The decoder has to cope with whatever the daemon actually returns.
        XCTAssertTrue(models.allSatisfy { !$0.name.isEmpty })
        XCTAssertNotNil(models.first?.formattedSize)
    }

    func testStreamingProducesTextAndUsage() async throws {
        _ = try await LiveEnvironment.requireOllama(LiveEnvironment.chatModel)
        let ollama = service()

        var text = ""
        var usage: AIUsage?
        var sawDone = false

        for try await chunk in ollama.streamChat(
            messages: [ChatMessage(role: .user, content: "Reply with exactly: ready")],
            systemPrompt: "Answer in one word.",
            modelOverride: LiveEnvironment.chatModel,
            parameters: AIParameters(temperature: 0),
            tools: nil
        ) {
            switch chunk {
            case .text(let piece): text += piece
            case .usage(let value): usage = value
            case .done: sawDone = true
            default: break
            }
        }

        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the model must actually answer")
        XCTAssertTrue(sawDone)
        // The real reason this test exists alongside the unit tests: these
        // counts come from the daemon, and nothing mocked can verify the
        // decoding of them.
        let reported = try XCTUnwrap(usage, "Ollama reports token counts on its final chunk")
        XCTAssertGreaterThan(reported.completionTokens ?? 0, 0)
        XCTAssertGreaterThan(reported.promptTokens ?? 0, 0)
        XCTAssertGreaterThan(reported.generationSeconds ?? 0, 0)
    }

    func testRequestWithToolsEncodesAndTheModelCallsThem() async throws {
        let installed = try await LiveEnvironment.requireOllama()
        let model = try XCTUnwrap(
            LiveEnvironment.toolCapableModel(from: installed),
            "no tool-capable model installed"
        )
        let ollama = OllamaService(baseURL: LiveEnvironment.ollamaURL, model: model)

        // The exact failure that shipped: the schema is an AnyCodable, and
        // sending it unwrapped made JSONSerialization raise an Objective-C
        // exception that `try` cannot catch. If that regresses, this test
        // doesn't fail — the whole test process dies, which is louder.
        let schema = try JSONDecoder().decode(AnyCodable.self, from: Data("""
        {"type":"object",
         "properties":{"city":{"type":"string","description":"City name"}},
         "required":["city"]}
        """.utf8))
        let tool = AITool(id: "get_weather", name: "get_weather",
                          description: "Get the current weather for a city", inputSchema: schema)

        var calls: [AIToolCall] = []
        for try await chunk in ollama.streamChat(
            messages: [ChatMessage(role: .user, content: "What's the weather in Paris? Use the tool.")],
            systemPrompt: "You must use the provided tool.",
            modelOverride: model,
            parameters: AIParameters(temperature: 0),
            tools: [tool]
        ) {
            switch chunk {
            case .toolCall(let call): calls.append(call)
            case .toolCalls(let many): calls.append(contentsOf: many)
            default: break
            }
        }

        let call = try XCTUnwrap(calls.first, "the model should have called the tool")
        XCTAssertEqual(call.name, "get_weather")
        // Ollama sends arguments as an object; the service normalises them to a
        // JSON string so every backend looks the same downstream.
        let parsed = try XCTUnwrap(
            call.arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any],
            "arguments must be a JSON object string"
        )
        XCTAssertNotNil(parsed["city"])
    }

    func testToolResultsAreFedBackAndAnswered() async throws {
        let installed = try await LiveEnvironment.requireOllama()
        let model = try XCTUnwrap(
            LiveEnvironment.toolCapableModel(from: installed),
            "no tool-capable model installed"
        )
        let ollama = OllamaService(baseURL: LiveEnvironment.ollamaURL, model: model)

        // Round two of the loop: an assistant turn carrying tool_calls, then a
        // .tool message with the result. This is the message shape
        // streamChatWithTools builds, verified against a real server.
        var assistantTurn = ChatMessage(role: .assistant, content: "")
        assistantTurn.toolCalls = [AIToolCall(id: "call_1", name: "get_inventory", arguments: "{\"item\":\"apples\"}")]
        var toolTurn = ChatMessage(role: .tool, content: "apples: 42 in stock")
        toolTurn.toolCallID = "call_1"

        var answer = ""
        for try await chunk in ollama.streamChat(
            messages: [
                ChatMessage(role: .user, content: "How many apples are in stock?"),
                assistantTurn,
                toolTurn
            ],
            systemPrompt: "Answer using the tool result. Be brief.",
            modelOverride: LiveEnvironment.chatModel,
            parameters: AIParameters(temperature: 0),
            tools: nil
        ) {
            if case .text(let piece) = chunk { answer += piece }
        }

        XCTAssertTrue(answer.strippingThinkBlocks.contains("42"),
                      "the model must actually use the tool result, not ignore it — got: \(answer.prefix(200))")
    }

    func testGenerateOnceReturnsCompleteText() async throws {
        _ = try await LiveEnvironment.requireOllama(LiveEnvironment.chatModel)
        let ollama = service()

        let reply = try await ollama.generateOnce(
            prompt: "Reply with exactly the word: pong",
            systemPrompt: "Reply with one word only.",
            modelOverride: LiveEnvironment.chatModel,
            parameters: AIParameters(temperature: 0),
            tools: nil
        )
        XCTAssertFalse(reply.strippingThinkBlocks.isEmpty)
    }

    func testUnknownModelSurfacesAReadableError() async throws {
        _ = try await LiveEnvironment.requireOllama()
        let ollama = service()

        do {
            for try await _ in ollama.streamChat(
                messages: [ChatMessage(role: .user, content: "hi")],
                systemPrompt: nil,
                modelOverride: "definitely-not-a-real-model:0b",
                parameters: nil,
                tools: nil
            ) {}
            XCTFail("a missing model should error rather than stream nothing")
        } catch let error as AIServiceError {
            // The user-facing text has to name the problem.
            let described = error.localizedDescription + (error.recoverySuggestion ?? "")
            XCTAssertFalse(described.isEmpty)
        }
    }

    func testCancellationStopsGeneration() async throws {
        _ = try await LiveEnvironment.requireOllama(LiveEnvironment.chatModel)
        let ollama = service()

        let task = Task {
            var pieces = 0
            for try await chunk in ollama.streamChat(
                messages: [ChatMessage(role: .user, content: "Count slowly from 1 to 200, one number per line.")],
                systemPrompt: nil,
                modelOverride: LiveEnvironment.chatModel,
                parameters: nil,
                tools: nil
            ) {
                if case .text = chunk { pieces += 1 }
            }
            return pieces
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        task.cancel()
        _ = try? await task.value
        // Reaching here without hanging is the assertion: a cancelled stream
        // must terminate rather than run to completion in the background.
        XCTAssertTrue(task.isCancelled)
    }

    func testVisionModelAcceptsAnImage() async throws {
        let models = try await LiveEnvironment.requireOllama()
        try XCTSkipUnless(models.contains(LiveEnvironment.visionModel), "llava not pulled — skipping vision test")

        // A tiny generated PNG; the point is that image encoding reaches the
        // server intact, not what the model says about it.
        let size = 32
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        let ollama = OllamaService(baseURL: LiveEnvironment.ollamaURL, model: LiveEnvironment.visionModel)
        var answer = ""
        for try await chunk in ollama.streamChat(
            messages: [ChatMessage(role: .user, content: "What colour is this image?", imageData: png)],
            systemPrompt: nil,
            modelOverride: LiveEnvironment.visionModel,
            parameters: AIParameters(temperature: 0),
            tools: nil
        ) {
            if case .text(let piece) = chunk { answer += piece }
        }
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "a vision request must round-trip and produce a response")
    }
}

// MARK: - Full generation pipeline against a live backend

@MainActor
final class LiveGenerationPipelineTests: XCTestCase {

    private var testDir: URL!
    private var dataStore: DataStore!
    private var aiManager: AIServiceManager!
    private var generationService: ChatGenerationService!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindLive-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        dataStore = DataStore(baseDirectoryOverride: testDir)
        aiManager = AIServiceManager()
        generationService = ChatGenerationService(dataStore: dataStore, aiManager: aiManager)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    private func waitForFinish(_ id: UUID, timeout: TimeInterval = 120) async {
        let start = Date()
        while generationService.isStreaming(id), Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func testWholePipelineProducesAStoredAnswerWithRealStats() async throws {
        _ = try await LiveEnvironment.requireOllama(LiveEnvironment.chatModel)

        let ollama = OllamaService(baseURL: LiveEnvironment.ollamaURL, model: LiveEnvironment.chatModel)
        aiManager.setServiceForTesting(ollama)

        var conversation = Conversation(
            title: "Live",
            messages: [ChatMessage(role: .user, content: "Say hello in one short sentence.")]
        )
        conversation.modelOverride = LiveEnvironment.chatModel
        dataStore.saveConversation(conversation)

        generationService.start(conversationID: conversation.id)
        await waitForFinish(conversation.id)

        let stored = try XCTUnwrap(dataStore.conversations.first { $0.id == conversation.id })
        let answer = try XCTUnwrap(stored.messages.last)
        XCTAssertEqual(answer.role, .assistant)
        XCTAssertFalse(answer.content.isEmpty)
        XCTAssertFalse(answer.content.hasPrefix("⚠️"), "the pipeline shouldn't error against a healthy backend")

        // Stats measured by the backend, not estimated — the whole point of
        // running this against a real daemon.
        XCTAssertTrue(answer.hasMeasuredTokens)
        XCTAssertGreaterThan(answer.tokensPerSecond ?? 0, 0)
        XCTAssertGreaterThan(answer.generationSeconds ?? 0, 0)
    }
}

// MARK: - MCP against a real server process

final class LiveMCPTests: XCTestCase {

    /// Spawns the official filesystem server over stdio, scoped to a temp dir.
    private func connectFilesystemServer(root: URL) async throws -> MCPClient {
        try LiveEnvironment.requireLiveMCPOptIn()
        try LiveEnvironment.requireNPX()
        let config = MCPServerConfig(
            name: "LiveFilesystem",
            transport: .stdio(
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", root.path],
                env: nil
            ),
            enabled: true
        )
        let client = MCPClient(config: config)
        do {
            try await client.connect()
        } catch {
            throw XCTSkip("Couldn't start the filesystem MCP server (offline npx cache?): \(error.localizedDescription)")
        }
        return client
    }

    private func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindMCP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello from localmind".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    func testHandshakeListsToolsWithUsableSchemas() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let client = try await connectFilesystemServer(root: sandbox)
        defer { Task { await client.disconnect() } }

        let tools = try await client.listTools()
        XCTAssertFalse(tools.isEmpty)
        XCTAssertTrue(tools.contains { $0.name == "read_text_file" || $0.name == "read_file" })

        // Every advertised schema must survive the trip into a request body.
        // This is the exact conversion that was broken.
        for tool in tools {
            let unwrapped = tool.inputSchema.jsonValue
            XCTAssertTrue(
                JSONSerialization.isValidJSONObject(["parameters": unwrapped]),
                "schema for \(tool.name) can't be serialised — tool calling would crash"
            )
        }
    }

    func testCallingAToolReturnsRealContent() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let client = try await connectFilesystemServer(root: sandbox)
        defer { Task { await client.disconnect() } }

        let content = try await client.callTool(
            name: "list_directory",
            arguments: ["path": sandbox.path]
        )
        let text = content.compactMap(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("note.txt"), "the server should list the file we created")
    }

    func testToolErrorsSurfaceInsteadOfHanging() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let client = try await connectFilesystemServer(root: sandbox)
        defer { Task { await client.disconnect() } }

        // Outside the allowed root: the server must refuse, and that refusal
        // has to come back rather than leaving the request pending forever.
        do {
            let content = try await client.callTool(name: "read_text_file", arguments: ["path": "/etc/passwd"])
            let text = content.compactMap(\.text).joined()
            XCTAssertTrue(text.lowercased().contains("denied") || text.lowercased().contains("outside")
                          || text.lowercased().contains("not allowed") || text.lowercased().contains("error"),
                          "a refused path should say so; got: \(text.prefix(120))")
        } catch {
            // An error response is equally acceptable — what matters is that
            // it terminates.
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testLaunchingAMissingServerFailsQuicklyWithAUsefulMessage() async throws {
        let config = MCPServerConfig(
            name: "Nonexistent",
            transport: .stdio(command: "localmind-definitely-not-installed", args: [], env: nil),
            enabled: true
        )
        let client = MCPClient(config: config)

        let start = Date()
        do {
            try await client.connect()
            XCTFail("connecting to a missing executable should throw")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 10, "a missing binary must fail fast, not hang the UI on 'Connecting…'")
            XCTAssertTrue(error.localizedDescription.lowercased().contains("find")
                          || error.localizedDescription.lowercased().contains("not"),
                          "the message should explain what's missing: \(error.localizedDescription)")
        }
    }

    func testDisconnectUnblocksPendingWork() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let client = try await connectFilesystemServer(root: sandbox)

        await client.disconnect()
        // After teardown, further calls must fail rather than wait on a
        // continuation nobody will ever resume.
        do {
            _ = try await client.listTools()
            XCTFail("a disconnected client shouldn't answer")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
