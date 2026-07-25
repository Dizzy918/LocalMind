//
 //  AIServiceProtocol.swift
 //  LocalMind
 //
 //  Created by Radoslav Slavov on 20.06.26.
 //
 
 import Foundation
 
 // MARK: - Tool Support
 
 /// Represents a tool that can be called by the AI model.
struct AITool: Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let inputSchema: AnyCodable
}

/// Represents a tool call made by the AI model.
struct AIToolCall: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let arguments: String
}

/// Represents the result of a tool call.
struct AIToolResult: Codable, Sendable, Identifiable {
    let id: String
    let toolCallId: String
    let content: String
    let isError: Bool
    /// Wall-clock duration of the call, when measured.
    let seconds: Double?

    init(id: String = UUID().uuidString, toolCallId: String, content: String, isError: Bool = false, seconds: Double? = nil) {
        self.id = id
        self.toolCallId = toolCallId
        self.content = content
        self.isError = isError
        self.seconds = seconds
    }
}

/// What a tool-augmented generation produced: the model's own text (tool
/// markers excluded, so it can be persisted as the answer) alongside a record
/// of every tool that ran.
struct ToolAugmentedAnswer: Sendable {
    /// Model-generated text across every round, joined — the answer to persist.
    var text: String
    /// Everything the loop streamed, including tool markers — what the user
    /// watched, used for throughput stats.
    var displayText: String
    /// Tools that ran, in call order.
    var toolRuns: [ToolRun]
    /// Backend-reported token usage, summed across rounds. nil when no backend
    /// volunteered counts, in which case callers fall back to TokenEstimator.
    var usage: AIUsage?
}
 
 // MARK: - AI Backend

/// Represents the available AI backends that the app can connect to.
enum AIBackend: String, Sendable, CaseIterable, Codable {
    case appleFoundationModels = "Apple Intelligence"
    case ollama = "Ollama"
    case openAICompatible = "OpenAI Compatible"
    case none = "No AI Available"

    /// SF Symbol icon name for this backend.
    var icon: String {
        switch self {
        case .appleFoundationModels: return "apple.intelligence"
        case .ollama: return "server.rack"
        case .openAICompatible: return "network"
        case .none: return "exclamationmark.triangle"
        }
    }
}

// MARK: - AI Service Protocol

/// Protocol that all AI service backends must conform to.
///
/// Each backend (Apple Foundation Models, Ollama, etc.) implements this
/// protocol to provide a unified interface for chat streaming and single-shot
/// generation. All implementations must be `Sendable` to support Swift concurrency.
protocol AIServiceProtocol: Sendable {
    /// Display name for this backend (e.g. "Ollama", "Apple Intelligence").
    var backendName: String { get }

    /// Which backend type this service represents.
    var backend: AIBackend { get }

    /// Check if this backend is currently available and ready to accept requests.
    /// - Returns: `true` if the backend is online and the model is loaded.
    func checkAvailability() async -> Bool

    /// Stream a chat response given a list of messages.
    /// - Parameters:
    ///   - messages: The conversation history to send.
    ///   - systemPrompt: An optional system prompt to prepend.
    ///   - modelOverride: An optional model identifier to use instead of the globally selected one.
    ///   - parameters: Optional parameters (temperature, maxTokens, contextLength) for generation.
    ///   - tools: Optional tools available for the model to call.
    /// - Returns: An `AsyncThrowingStream` that yields incremental text chunks or tool calls.
    func streamChat(messages: [ChatMessage], systemPrompt: String?, modelOverride: String?, parameters: AIParameters?, tools: [AITool]?) -> AsyncThrowingStream<AIStreamChunk, Error>

    /// Generate a single complete response (non-streaming).
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - systemPrompt: An optional system prompt to prepend.
    ///   - modelOverride: An optional model identifier to use instead of the globally selected one.
    ///   - parameters: Optional parameters for generation.
    ///   - tools: Optional tools available for the model to call.
    /// - Returns: The full generated response text.
    func generateOnce(prompt: String, systemPrompt: String?, modelOverride: String?, parameters: AIParameters?, tools: [AITool]?) async throws -> String
}

/// Token counts reported by the backend itself. Preferred over
/// `TokenEstimator`, which is a heuristic — when the server tells us what it
/// actually processed, the stats should say so rather than guess.
struct AIUsage: Sendable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    /// Time the backend spent generating (not counting prompt evaluation),
    /// which yields a truer tokens/sec than wall-clock does.
    var generationSeconds: Double?

    var isEmpty: Bool {
        promptTokens == nil && completionTokens == nil && generationSeconds == nil
    }
}

/// Adds two optionals, treating nil as "no value reported" rather than zero —
/// so a backend that reports nothing doesn't turn a real total into 0.
func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
    guard lhs != nil || rhs != nil else { return nil }
    return (lhs ?? 0) + (rhs ?? 0)
}

func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
    guard lhs != nil || rhs != nil else { return nil }
    return (lhs ?? 0) + (rhs ?? 0)
}

/// A chunk of streaming response from an AI model.
enum AIStreamChunk: Sendable {
    case text(String)
    case toolCall(AIToolCall)
    case toolCalls([AIToolCall])
    /// Backend-reported token usage, emitted at most once near the end.
    case usage(AIUsage)
    /// Tools a backend ran on its own behalf. Apple Intelligence owns its tool
    /// loop inside the framework, so it reports completed runs rather than
    /// asking the app to execute calls.
    case toolRuns([ToolRun])
    case done
}

// MARK: - AI Service Error

nonisolated enum AIServiceError: Error, LocalizedError {
    case backendUnavailable(String)
    case serverError(String)
    case modelNotFound(String)
    case generationFailed(String)
    case networkError(String)
    case timeout
    case noBackendAvailable

    var errorDescription: String? {
        switch self {
        case .backendUnavailable(let msg): return "AI Backend Unavailable: \(msg)"
        case .serverError(let msg): return "Server Error: \(msg)"
        case .modelNotFound(let msg): return "Model Not Found: \(msg)"
        case .generationFailed(let msg): return "Generation Failed: \(msg)"
        case .networkError(let msg): return "Network Error: \(msg)"
        case .timeout: return "Request timed out. The model may be loading — try again in a moment."
        case .noBackendAvailable: return "No AI backend is connected. Start Ollama or another local server."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .backendUnavailable: return "Make sure your AI server is running and try again."
        case .serverError: return "The server returned an error. Check the server logs for details."
        case .modelNotFound: return "The selected model may have been removed. Choose a different model in Settings."
        case .generationFailed: return "The model failed to generate a response. Try rephrasing your message."
        case .networkError: return "Check that the server URL is correct and the server is reachable."
        case .timeout: return "The model may still be loading into memory. Wait a moment and try again."
        case .noBackendAvailable: return "Start Ollama (ollama serve) or LM Studio, then the app will connect automatically."
        }
    }
}

// MARK: - Default Parameter Convenience

extension AIServiceProtocol {
    /// Stream chat without a system prompt or model override.
    func streamChat(messages: [ChatMessage]) -> AsyncThrowingStream<AIStreamChunk, Error> {
        streamChat(messages: messages, systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil)
    }

    /// Generate a single response without a system prompt or model override.
    func generateOnce(prompt: String) async throws -> String {
        try await generateOnce(prompt: prompt, systemPrompt: nil, modelOverride: nil, parameters: nil, tools: nil)
    }

    /// Stream chat with a system prompt but no model override.
    func streamChat(messages: [ChatMessage], systemPrompt: String?) -> AsyncThrowingStream<AIStreamChunk, Error> {
        streamChat(messages: messages, systemPrompt: systemPrompt, modelOverride: nil, parameters: nil, tools: nil)
    }

    /// Generate a single response with a system prompt but no model override.
    func generateOnce(prompt: String, systemPrompt: String?) async throws -> String {
        try await generateOnce(prompt: prompt, systemPrompt: systemPrompt, modelOverride: nil, parameters: nil, tools: nil)
    }
}