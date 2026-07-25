//
//  OpenAIWireTests.swift
//  LocalMindTests
//
//  Drives OpenAICompatibleService against a real HTTP server running inside the
//  test process.
//
//  There's no LM Studio or llama.cpp to point at in CI, so this backend had no
//  coverage of the parts that only exist on the wire: URLSession streaming, SSE
//  framing, tool-call reassembly across chunks, usage parsing, and error
//  handling. A scripted local server exercises all of it deterministically —
//  including the malformed and hostile responses a real server occasionally
//  produces, which are awkward to provoke on demand from a live one.
//

import Foundation
import Network
import XCTest
@testable import LocalMind

/// A minimal HTTP/1.1 server that replays a canned response. Enough for
/// `POST /v1/chat/completions` and `GET /v1/models`.
final class ScriptedHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "scripted-http")
    /// Raw HTTP response bytes, chosen per request path.
    private let respond: @Sendable (String) -> String
    private(set) var port: UInt16 = 0
    /// Bodies the server received, for asserting what the client actually sent.
    private let lock = NSLock()
    private var _receivedBodies: [String] = []
    var receivedBodies: [String] {
        lock.lock(); defer { lock.unlock() }
        return _receivedBodies
    }

    init(respond: @escaping @Sendable (String) -> String) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "ScriptedHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
    }

    func stop() { listener.cancel() }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let text = String(data: accumulated, encoding: .utf8) else {
                if isComplete { connection.cancel() }
                return
            }

            // Wait for the full request: headers, then Content-Length bytes.
            guard let headerEnd = text.range(of: "\r\n\r\n") else {
                self.receive(connection, buffer: accumulated)
                return
            }
            let headers = String(text[..<headerEnd.lowerBound])
            let body = String(text[headerEnd.upperBound...])
            let expected = Self.contentLength(in: headers)
            if body.utf8.count < expected {
                self.receive(connection, buffer: accumulated)
                return
            }

            if !body.isEmpty {
                self.lock.lock(); self._receivedBodies.append(body); self.lock.unlock()
            }

            let path = headers.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let response = self.respond(path)
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func contentLength(in headers: String) -> Int {
        for line in headers.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    /// Wraps SSE `data:` frames in a complete chunked-free HTTP response.
    static func sse(_ frames: [String]) -> String {
        let body = frames.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        return """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
    }

    static func json(_ body: String, status: Int = 200) -> String {
        """
        HTTP/1.1 \(status) OK\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
    }
}

final class OpenAIWireTests: XCTestCase {

    private var server: ScriptedHTTPServer!

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func startServer(_ respond: @escaping @Sendable (String) -> String) throws -> OpenAICompatibleService {
        server = try ScriptedHTTPServer(respond: respond)
        try server.start()
        return OpenAICompatibleService(baseURL: server.baseURL, model: "test-model", displayName: "Scripted")
    }

    private func collect(_ stream: AsyncThrowingStream<AIStreamChunk, Error>) async throws
        -> (text: String, calls: [AIToolCall], usage: AIUsage?) {
        var text = ""
        var calls: [AIToolCall] = []
        var usage: AIUsage?
        for try await chunk in stream {
            switch chunk {
            case .text(let piece): text += piece
            case .toolCall(let call): calls.append(call)
            case .toolCalls(let many): calls.append(contentsOf: many)
            case .usage(let value): usage = value
            case .toolRuns, .done: break
            }
        }
        return (text, calls, usage)
    }

    // MARK: - Streaming basics

    func testStreamedTextIsConcatenatedInOrder() async throws {
        let service = try startServer { _ in
            ScriptedHTTPServer.sse([
                #"{"choices":[{"delta":{"content":"Hello"}}]}"#,
                #"{"choices":[{"delta":{"content":", "}}]}"#,
                #"{"choices":[{"delta":{"content":"world"}}]}"#
            ])
        }
        let result = try await collect(service.streamChat(
            messages: [ChatMessage(role: .user, content: "hi")],
            systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil
        ))
        XCTAssertEqual(result.text, "Hello, world")
    }

    func testUsageIsReadFromAFinalChunkWithoutChoices() async throws {
        // The shape that previously failed to decode and threw the counts away.
        let service = try startServer { _ in
            ScriptedHTTPServer.sse([
                #"{"choices":[{"delta":{"content":"hi"}}]}"#,
                #"{"id":"x","usage":{"prompt_tokens":12,"completion_tokens":34}}"#
            ])
        }
        let result = try await collect(service.streamChat(
            messages: [ChatMessage(role: .user, content: "hi")],
            systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil
        ))
        XCTAssertEqual(result.text, "hi")
        XCTAssertEqual(result.usage?.promptTokens, 12)
        XCTAssertEqual(result.usage?.completionTokens, 34)
    }

    // MARK: - Tool-call reassembly on the wire

    func testFragmentedToolCallIsReassembledAcrossChunks() async throws {
        // Exactly how OpenAI streams a tool call: name in the first fragment,
        // arguments dribbled out a few characters at a time.
        let service = try startServer { _ in
            ScriptedHTTPServer.sse([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"get_weather","arguments":""}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\":\"Paris\"}"}}]}}]}"#
            ])
        }
        let result = try await collect(service.streamChat(
            messages: [ChatMessage(role: .user, content: "weather?")],
            systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil
        ))

        XCTAssertEqual(result.calls.count, 1, "fragments must merge into one call, not three broken ones")
        XCTAssertEqual(result.calls.first?.name, "get_weather")
        XCTAssertEqual(result.calls.first?.id, "call_a")
        XCTAssertEqual(result.calls.first?.arguments, "{\"city\":\"Paris\"}")
    }

    func testParallelToolCallsStaySeparate() async throws {
        let service = try startServer { _ in
            ScriptedHTTPServer.sse([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"first","arguments":"{"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"second","arguments":"{"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"}"}}]}}]}"#
            ])
        }
        let result = try await collect(service.streamChat(
            messages: [ChatMessage(role: .user, content: "do both")],
            systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil
        ))
        XCTAssertEqual(result.calls.map(\.name), ["first", "second"])
        XCTAssertTrue(result.calls.allSatisfy { $0.arguments == "{}" })
    }

    // MARK: - Hostile and malformed responses

    func testMalformedFramesAreSkippedWithoutLosingGoodOnes() async throws {
        let service = try startServer { _ in
            ScriptedHTTPServer.sse([
                #"{"choices":[{"delta":{"content":"good"}}]}"#,
                "{not json at all",
                #"{"unexpected":"shape"}"#,
                #"{"choices":[{"delta":{"content":" news"}}]}"#
            ])
        }
        let result = try await collect(service.streamChat(
            messages: [ChatMessage(role: .user, content: "hi")],
            systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil
        ))
        XCTAssertEqual(result.text, "good news", "a bad frame must not abort the stream")
    }

    func testNonOKStatusThrows() async throws {
        let service = try startServer { _ in
            ScriptedHTTPServer.json(#"{"error":"model not loaded"}"#, status: 500)
        }
        do {
            _ = try await collect(service.streamChat(
                messages: [ChatMessage(role: .user, content: "hi")],
                systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil
            ))
            XCTFail("a 500 should surface as an error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testEmptyStreamCompletesInsteadOfHanging() async throws {
        let service = try startServer { _ in ScriptedHTTPServer.sse([]) }
        let result = try await collect(service.streamChat(
            messages: [ChatMessage(role: .user, content: "hi")],
            systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil
        ))
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.calls.isEmpty)
    }

    func testToolCallWithNoNameIsDropped() async throws {
        let service = try startServer { _ in
            ScriptedHTTPServer.sse([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}"#
            ])
        }
        let result = try await collect(service.streamChat(
            messages: [ChatMessage(role: .user, content: "hi")],
            systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil
        ))
        XCTAssertTrue(result.calls.isEmpty, "a nameless call can't be executed and must not be emitted")
    }

    // MARK: - What we send

    func testToolSchemaAndToolMessagesReachTheServerIntact() async throws {
        let service = try startServer { _ in
            ScriptedHTTPServer.sse([#"{"choices":[{"delta":{"content":"ok"}}]}"#])
        }
        let schema = try JSONDecoder().decode(AnyCodable.self, from: Data(
            #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#.utf8
        ))
        var assistantTurn = ChatMessage(role: .assistant, content: "")
        assistantTurn.toolCalls = [AIToolCall(id: "call_1", name: "read", arguments: "{\"path\":\"/tmp\"}")]
        var toolTurn = ChatMessage(role: .tool, content: "file contents")
        toolTurn.toolCallID = "call_1"

        _ = try await collect(service.streamChat(
            messages: [ChatMessage(role: .user, content: "read it"), assistantTurn, toolTurn],
            systemPrompt: "sys",
            modelOverride: nil,
            parameters: AIParameters(temperature: 0.4),
            tools: [AITool(id: "read", name: "read", description: "Read a file", inputSchema: schema)]
        ))

        let body = try XCTUnwrap(server.receivedBodies.first)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )

        // The schema survived unwrapping and is a real nested object, not a
        // string or a mangled wrapper.
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let parameters = try XCTUnwrap((tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertNotNil(parameters["properties"])

        // Tool correlation fields are present so the server can match result
        // to call.
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let toolMessage = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" })
        XCTAssertEqual(toolMessage["tool_call_id"] as? String, "call_1")
        let assistantMessage = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        XCTAssertNotNil(assistantMessage["tool_calls"])
    }

    func testModelListingParses() async throws {
        let service = try startServer { _ in
            ScriptedHTTPServer.json(#"{"data":[{"id":"m1","object":"model"},{"id":"m2"}]}"#)
        }
        let models = try await service.listModels()
        XCTAssertEqual(models.map(\.id), ["m1", "m2"])
    }

    func testAvailabilityReflectsServerHealth() async throws {
        let healthy = try startServer { _ in ScriptedHTTPServer.json(#"{"data":[]}"#) }
        let up = await healthy.checkAvailability()
        XCTAssertTrue(up)
        server.stop()

        // Nothing listening on that port any more.
        let down = await healthy.checkAvailability()
        XCTAssertFalse(down)
    }
}
