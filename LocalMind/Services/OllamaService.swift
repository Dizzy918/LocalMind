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
                            var toolDict: [String: Any] = [
                                "type": "function",
                                "function": [
                                    "name": tool.name,
                                    "description": tool.description,
                                    "parameters": tool.inputSchema
                                ]
                            ]
                            return toolDict
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

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

                    var toolCallBuffer: [String: (name: String, arguments: String)] = [:]

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
    }
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