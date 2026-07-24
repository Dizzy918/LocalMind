//
//  OpenAICompatibleService.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 23.06.26.
//

import Foundation

/// OpenAI-compatible REST API service — connects to any local server that
/// implements the OpenAI `/v1/chat/completions` API (LM Studio, llama.cpp,
/// Jan, LocalAI, GPT4All, etc.).
actor OpenAICompatibleService: AIServiceProtocol {
    nonisolated let backendName: String
    nonisolated let backend: AIBackend = .openAICompatible

    private let baseURL: URL
    private var selectedModel: String

    init(
        baseURL: URL = URL(string: "http://localhost:1234")!,
        model: String = "default",
        displayName: String = "LM Studio"
    ) {
        self.baseURL = baseURL
        self.selectedModel = model
        self.backendName = displayName
    }

    func checkAvailability() async -> Bool {
        let url = baseURL.appendingPathComponent("v1/models")
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func listModels() async throws -> [OpenAIModel] {
        let url = baseURL.appendingPathComponent("v1/models")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw AIServiceError.serverError("Failed to fetch models from OpenAI-compatible server")
        }

        let modelsResponse = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return modelsResponse.data
    }

    func setModel(_ model: String) {
        selectedModel = model
    }

    func getModel() -> String {
        selectedModel
    }

    nonisolated func streamChat(
        messages: [ChatMessage],
        systemPrompt: String?,
        modelOverride: String?,
        parameters: AIParameters?,
        tools: [AITool]?
    ) -> AsyncThrowingStream<AIStreamChunk, Error> {
        let baseURL = self.baseURL

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("v1/chat/completions")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 120

                    var apiMessages: [[String: Any]] = []

                    if let systemPrompt {
                        apiMessages.append(["role": "system", "content": systemPrompt])
                    }

                    for msg in messages {
                        var msgDict: [String: Any] = [
                            "role": msg.role.rawValue,
                            "content": msg.content,
                        ]
                        // Tool result turns correlate back to their call by id.
                        if msg.role == .tool, let callID = msg.toolCallID {
                            msgDict["tool_call_id"] = callID
                        }
                        // An assistant turn that requested tools carries them so
                        // the follow-up round has coherent context.
                        if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                            msgDict["tool_calls"] = toolCalls.map { call in
                                [
                                    "id": call.id,
                                    "type": "function",
                                    "function": [
                                        "name": call.name,
                                        // OpenAI expects arguments as a JSON string.
                                        "arguments": call.arguments,
                                    ],
                                ] as [String: Any]
                            }
                        }
                        // If there's an image attached, encode as a multi-part content array
                        if let imgData = msg.imageData {
                            let base64 = imgData.base64EncodedString()
                            msgDict["content"] = [
                                ["type": "text", "text": msg.content],
                                [
                                    "type": "image_url",
                                    "image_url": ["url": "data:image/png;base64,\(base64)"],
                                ],
                            ] as [[String: Any]]
                        }
                        apiMessages.append(msgDict)
                    }

                    let actualModel: String
                    if let modelOverride {
                        actualModel = modelOverride
                    } else {
                        actualModel = await self.getModel()
                    }

                    var body: [String: Any] = [
                        "model": actualModel,
                        "messages": apiMessages,
                        "stream": true,
                    ]

                    // Add tools if provided
                    if let tools = tools, !tools.isEmpty {
                        let openAITools = tools.map { tool -> [String: Any] in
                            [
                                "type": "function",
                                "function": [
                                    "name": tool.name,
                                    "description": tool.description,
                                    "parameters": tool.inputSchema
                                ]
                            ]
                        }
                        body["tools"] = openAITools
                        body["tool_choice"] = "auto"
                    }

                    if let params = parameters {
                        body["temperature"] = params.temperature
                        if let topP = params.topP {
                            body["top_p"] = topP
                        }
                        if let maxTokens = params.maxTokens {
                            body["max_tokens"] = maxTokens
                        }
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200
                    else {
                        throw AIServiceError.serverError("OpenAI-compatible server returned non-200 status")
                    }

                    // OpenAI streams tool calls as deltas keyed by `index`: the
                    // first fragment carries id + name, later fragments append
                    // `arguments` a few characters at a time. Accumulate them
                    // and emit complete calls once, at the end — yielding each
                    // raw fragment (as the old code did) produced calls with
                    // empty names and truncated JSON.
                    var assembler = OpenAIToolCallAssembler()

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        // SSE lines are prefixed with "data: "
                        guard line.hasPrefix("data: ") else { continue }

                        let payload = String(line.dropFirst(6))

                        // Stream termination signal
                        if payload == "[DONE]" {
                            break
                        }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
                        else {
                            continue
                        }

                        // Accumulate streamed tool-call fragments by index.
                        if let toolCalls = chunk.choices.first?.delta.toolCalls {
                            assembler.ingest(toolCalls)
                        }

                        if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                    }

                    // Flush the reassembled tool calls, in index order.
                    let completed = assembler.assembled()
                    if !completed.isEmpty {
                        continuation.yield(.toolCalls(completed))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    nonisolated func generateOnce(prompt: String, systemPrompt: String?, modelOverride: String?, parameters: AIParameters?, tools: [AITool]?) async throws -> String {
        var result = ""
        let messages = [ChatMessage(role: .user, content: prompt)]
        for try await chunk in streamChat(messages: messages, systemPrompt: systemPrompt, modelOverride: modelOverride, parameters: parameters, tools: tools) {
            if case .text(let text) = chunk {
                result += text
            }
        }
        return result
    }
}

// MARK: - Streaming tool-call reassembly

/// Mutable accumulator for a tool call being streamed in `index`-keyed
/// fragments across many SSE chunks.
private struct PartialToolCall {
    var id: String?
    var name: String?
    var arguments: String = ""
}

/// Reassembles OpenAI streaming tool-call deltas into complete calls. The
/// server sends one fragment per SSE chunk keyed by `index`: the first carries
/// `id` + `name`, later ones append a few characters of `arguments`. Extracted
/// from the stream loop so the merge logic is unit-testable without a live
/// server. Fragments with no usable name are dropped.
struct OpenAIToolCallAssembler {
    private var byIndex: [Int: PartialToolCall] = [:]
    /// First-seen order of indices, so calls come out the way they arrived
    /// even if a server numbers them oddly.
    private var order: [Int] = []

    mutating func ingest(_ fragments: [OpenAIStreamChunk.OpenAIToolCall]) {
        for fragment in fragments {
            let index = fragment.index ?? 0
            if byIndex[index] == nil { order.append(index) }
            var partial = byIndex[index] ?? PartialToolCall()
            if let id = fragment.id { partial.id = id }
            if let name = fragment.function?.name { partial.name = name }
            if let args = fragment.function?.arguments { partial.arguments += args }
            byIndex[index] = partial
        }
    }

    func assembled() -> [AIToolCall] {
        order.compactMap { index -> AIToolCall? in
            guard let partial = byIndex[index], let name = partial.name, !name.isEmpty else { return nil }
            return AIToolCall(
                id: partial.id ?? UUID().uuidString,
                name: name,
                arguments: partial.arguments.isEmpty ? "{}" : partial.arguments
            )
        }
    }
}

// MARK: - Response Models

nonisolated struct OpenAIStreamChunk: Decodable, Sendable {
    let id: String?
    let object: String?
    let choices: [OpenAIStreamChoice]

    nonisolated struct OpenAIStreamChoice: Decodable, Sendable {
        let index: Int?
        let delta: OpenAIStreamDelta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    nonisolated struct OpenAIStreamDelta: Decodable, Sendable {
        let role: String?
        let content: String?
        let toolCalls: [OpenAIToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content, toolCalls = "tool_calls"
        }
    }

    nonisolated struct OpenAIToolCall: Decodable, Sendable {
        let index: Int?
        let id: String?
        let type: String?
        let function: OpenAIFunctionCall?
    }

    nonisolated struct OpenAIFunctionCall: Decodable, Sendable {
        let name: String?
        let arguments: String?
    }
}

nonisolated struct OpenAIModel: Identifiable, Decodable, Sendable {
    let id: String
    let object: String?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case ownedBy = "owned_by"
    }
}

nonisolated struct OpenAIModelsResponse: Decodable, Sendable {
    let data: [OpenAIModel]
}

// MARK: - Local AI Server Presets

nonisolated struct LocalAIServerPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let defaultPort: Int
    let defaultURL: URL
}

extension LocalAIServerPreset {
    static let presets: [LocalAIServerPreset] = [
        LocalAIServerPreset(
            id: "lmstudio",
            name: "LM Studio",
            defaultPort: 1234,
            defaultURL: URL(string: "http://localhost:1234")!
        ),
        LocalAIServerPreset(
            id: "llamacpp",
            name: "llama.cpp",
            defaultPort: 8080,
            defaultURL: URL(string: "http://localhost:8080")!
        ),
        LocalAIServerPreset(
            id: "jan",
            name: "Jan",
            defaultPort: 1337,
            defaultURL: URL(string: "http://localhost:1337")!
        ),
        LocalAIServerPreset(
            id: "localai",
            name: "LocalAI",
            defaultPort: 8080,
            defaultURL: URL(string: "http://localhost:8080")!
        ),
        LocalAIServerPreset(
            id: "gpt4all",
            name: "GPT4All",
            defaultPort: 4891,
            defaultURL: URL(string: "http://localhost:4891")!
        ),
        LocalAIServerPreset(
            id: "custom",
            name: "Custom",
            defaultPort: 1234,
            defaultURL: URL(string: "http://localhost:1234")!
        ),
    ]
}