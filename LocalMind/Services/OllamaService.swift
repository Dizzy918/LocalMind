//
//  OllamaService.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation

/// Ollama REST API service — connects to a locally running Ollama instance.
actor OllamaService: AIServiceProtocol {
    nonisolated let backendName = "Ollama"
    nonisolated let backend: AIBackend = .ollama

    private let baseURL: URL
    private var selectedModel: String

    init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "qwen3:8b") {
        self.baseURL = baseURL
        self.selectedModel = model
    }

    func checkAvailability() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func listModels() async throws -> [OllamaModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
        return response.models
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
                    let url = baseURL.appendingPathComponent("api/chat")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 120

                    var ollamaMessages: [[String: Any]] = []

                    if let systemPrompt {
                        ollamaMessages.append(["role": "system", "content": systemPrompt])
                    }

                    for msg in messages {
                        var msgDict: [String: Any] = [
                            "role": msg.role.rawValue,
                            "content": msg.content,
                        ]
                        // An assistant turn that requested tools carries them back
                        // so the follow-up round has coherent context. Ollama
                        // takes arguments as a JSON object (not a string), so
                        // decode our stored string form back into one.
                        if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                            msgDict["tool_calls"] = toolCalls.map { call -> [String: Any] in
                                let argsObject = call.arguments.data(using: .utf8)
                                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
                                return [
                                    "function": [
                                        "name": call.name,
                                        "arguments": argsObject,
                                    ],
                                ]
                            }
                        }
                        // If there's an image attached, convert it to Base64 for Ollama
                        if let imgData = msg.imageData {
                            msgDict["images"] = [imgData.base64EncodedString()]
                        }
                        ollamaMessages.append(msgDict)
                    }

                    let actualModel: String
                    if let modelOverride {
                        actualModel = modelOverride
                    } else {
                        actualModel = await self.getModel()
                    }

                    var body: [String: Any] = [
                        "model": actualModel,
                        "messages": ollamaMessages,
                        "stream": true,
                        // SPEED HACK: Keep the model loaded in RAM for 1 hour so follow-up chats are instantaneous
                        "keep_alive": "1h"
                    ]

                    // Add tools if provided (Ollama supports tools via the "tools" parameter)
                    if let tools = tools, !tools.isEmpty {
                        let ollamaTools = tools.map { tool -> [String: Any] in
                            [
                                "type": "function",
                                "function": [
                                    "name": tool.name,
                                    "description": tool.description,
                                    "parameters": tool.inputSchema.jsonValue
                                ]
                            ]
                        }
                        body["tools"] = ollamaTools
                    }

                    if let params = parameters {
                        var options: [String: Any] = [:]
                        options["temperature"] = params.temperature
                        if let topP = params.topP {
                            options["top_p"] = topP
                        }
                        if let maxTokens = params.maxTokens {
                            options["num_predict"] = maxTokens
                        }
                        if let contextLength = params.contextLength {
                            options["num_ctx"] = contextLength
                        }
                        body["options"] = options
                    }

                    request.httpBody = try encodeChatRequestBody(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIServiceError.networkError("No HTTP response from Ollama")
                    }

                    if httpResponse.statusCode != 200 {
                        // Try to read the error body for a useful message
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 500 { break }
                        }
                        if httpResponse.statusCode == 404 {
                            throw AIServiceError.modelNotFound("Model '\(actualModel)' not found on Ollama. \(errorBody)")
                        }
                        throw AIServiceError.serverError("Ollama returned HTTP \(httpResponse.statusCode): \(errorBody)")
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        guard let data = line.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OllamaChatChunk.self, from: data)
                        else {
                            continue
                        }

                        if let message = chunk.message {
                            // Handle tool calls in the message
                            if let toolCalls = message.toolCalls {
                                for toolCall in toolCalls {
                                    continuation.yield(.toolCall(AIToolCall(
                                        id: toolCall.id ?? UUID().uuidString,
                                        name: toolCall.function?.name ?? "",
                                        arguments: toolCall.function?.arguments ?? "{}"
                                    )))
                                }
                            }

                            if let content = message.content, !content.isEmpty {
                                continuation.yield(.text(content))
                            }
                        }

                        if chunk.done {
                            if let usage = chunk.usage {
                                continuation.yield(.usage(usage))
                            }
                            continuation.yield(.done)
                            break
                        }
                    }

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

    // MARK: - Model Management

    /// Downloads a model from the Ollama registry, yielding progress as it
    /// streams. Drives the in-app model manager so nobody needs a terminal.
    nonisolated func pullModel(_ name: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        let baseURL = self.baseURL
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 3600 // large models take a while
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": name,
                        "stream": true
                    ])

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw AIServiceError.serverError("Ollama pull failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let data = line.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OllamaPullChunk.self, from: data) else { continue }
                        if let error = chunk.error {
                            throw AIServiceError.serverError(error)
                        }
                        continuation.yield(OllamaPullProgress(
                            status: chunk.status ?? "",
                            completed: chunk.completed,
                            total: chunk.total
                        ))
                        if chunk.status == "success" { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Removes a model from the local Ollama store.
    func deleteModel(_ name: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Newer Ollama expects "model", older releases used "name" — send both.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "name": name])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIServiceError.serverError("Ollama couldn't delete '\(name)' (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
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

// MARK: - Ollama Response Models

nonisolated struct OllamaChatChunk: Decodable, Sendable {
    let message: OllamaChatMessage?
    let done: Bool
    /// Ollama reports real token counts (and nanosecond timings) on the final
    /// chunk. These beat TokenEstimator's heuristic, so the stats use them.
    let promptEvalCount: Int?
    let evalCount: Int?
    let evalDuration: Int64?

    enum CodingKeys: String, CodingKey {
        case message, done
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
    }

    /// Usage from the final chunk, or nil when this chunk carried none.
    var usage: AIUsage? {
        let value = AIUsage(
            promptTokens: promptEvalCount,
            completionTokens: evalCount,
            // eval_duration is in nanoseconds.
            generationSeconds: evalDuration.map { Double($0) / 1_000_000_000 }
        )
        return value.isEmpty ? nil : value
    }

    nonisolated struct OllamaChatMessage: Decodable, Sendable {
        let role: String?
        let content: String?
        let toolCalls: [OllamaToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content, toolCalls = "tool_calls"
        }
    }

    nonisolated struct OllamaToolCall: Decodable, Sendable {
        let id: String?
        let type: String?
        let function: OllamaFunctionCall?
    }

    nonisolated struct OllamaFunctionCall: Decodable, Sendable {
        let name: String?
        let arguments: String?

        enum CodingKeys: String, CodingKey {
            case name, arguments
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            // Ollama sends arguments as a JSON object (unlike OpenAI's
            // stringified JSON); accept both and normalise to a string.
            if let str = try? c.decodeIfPresent(String.self, forKey: .arguments) {
                arguments = str
            } else if let obj = try? c.decodeIfPresent(AnyCodable.self, forKey: .arguments),
                      let data = try? JSONEncoder().encode(obj) {
                arguments = String(data: data, encoding: .utf8)
            } else {
                arguments = nil
            }
        }
    }
}

/// One progress tick of a model download.
nonisolated struct OllamaPullProgress: Sendable {
    let status: String
    let completed: Int64?
    let total: Int64?

    /// 0…1 when the current layer reports sizes, else nil (status-only tick).
    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
}

private nonisolated struct OllamaPullChunk: Decodable, Sendable {
    let status: String?
    let completed: Int64?
    let total: Int64?
    let error: String?
}

nonisolated struct OllamaModel: Identifiable, Decodable, Sendable {
    let name: String
    let size: Int64?
    let digest: String?

    var id: String { name }

    var formattedSize: String {
        guard let size else { return "Unknown" }
        let gb = Double(size) / 1_073_741_824
        return String(format: "%.1f GB", gb)
    }
}

nonisolated struct OllamaModelsResponse: Decodable, Sendable {
    let models: [OllamaModel]
}