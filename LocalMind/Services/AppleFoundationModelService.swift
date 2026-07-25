//
//  AppleFoundationModelService.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Bridges one of the app's MCP tools into a Foundation Models `Tool`.
///
/// Apple Intelligence ran without tools at all: the backend accepted a `tools`
/// argument and ignored it, so anyone using the on-device model — the default
/// when it's available — had MCP servers that connected, listed their tools,
/// and never fired.
///
/// Unlike the OpenAI/Ollama path, the framework owns the tool loop here: the
/// session calls `call(arguments:)` and continues the turn itself, so this type
/// only has to execute the call and record it for the transcript.
@available(macOS 26.0, *)
final class MCPBridgeTool: FoundationModels.Tool, @unchecked Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    /// Runs performed through this tool, collected for the message transcript.
    private(set) var runs: [ToolRun] = []
    private let lock = NSLock()

    init?(tool: AITool) {
        self.name = tool.name
        self.description = tool.description
        guard let schema = Self.schema(named: tool.name, from: tool.inputSchema) else { return nil }
        self.parameters = schema
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let argumentText = Self.jsonString(from: arguments)
        let started = Date()
        do {
            let parsed = (argumentText.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            let content = try await Self.execute(name: name, arguments: parsed)
            let text = content.compactMap(\.text).joined(separator: "\n")
            let result = text.isEmpty ? "(empty result)" : text
            record(arguments: argumentText, result: result, isError: false, started: started)
            return result
        } catch {
            let message = "Error — \(error.localizedDescription)"
            record(arguments: argumentText, result: message, isError: true, started: started)
            // Handed back as output rather than thrown: the model can say the
            // tool failed, which is more useful than aborting the whole turn.
            return message
        }
    }

    /// MCPService is main-actor isolated and injected rather than global, so
    /// the bridge reaches it the same way the App Intents do.
    @MainActor
    private static func execute(name: String, arguments: [String: Any]) async throws -> [MCPToolContent] {
        guard let service = AppServices.aiManager?.mcpService else {
            throw AIServiceError.backendUnavailable("No tool backend is connected.")
        }
        return try await service.callTool(name: name, arguments: arguments)
    }

    private func record(arguments: String, result: String, isError: Bool, started: Date) {
        lock.lock(); defer { lock.unlock() }
        runs.append(ToolRun(
            name: name,
            arguments: arguments,
            result: result,
            isError: isError,
            seconds: Date().timeIntervalSince(started)
        ))
    }

    func drainRuns() -> [ToolRun] {
        lock.lock(); defer { lock.unlock() }
        let collected = runs
        runs.removeAll()
        return collected
    }

    // MARK: - JSON Schema → GenerationSchema

    /// Translates the JSON Schema an MCP server advertises into the dynamic
    /// schema Foundation Models wants. Only the subset MCP tools actually use
    /// is mapped; anything unrecognised becomes a string, which the server
    /// itself will validate anyway.
    private static func schema(named name: String, from input: AnyCodable) -> GenerationSchema? {
        let object = (input.value as? [String: Any]) ?? [:]
        let properties = (object["properties"] as? [String: Any]) ?? [:]
        let required = Set((object["required"] as? [String]) ?? [])

        let fields = properties.compactMap { key, raw -> DynamicGenerationSchema.Property? in
            let definition = (raw as? [String: Any]) ?? [:]
            return DynamicGenerationSchema.Property(
                name: key,
                description: definition["description"] as? String,
                schema: dynamicSchema(for: definition),
                isOptional: !required.contains(key)
            )
        }

        let root = DynamicGenerationSchema(name: name, description: nil, properties: fields)
        return try? GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamicSchema(for definition: [String: Any]) -> DynamicGenerationSchema {
        switch definition["type"] as? String {
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let items = (definition["items"] as? [String: Any]) ?? [:]
            return DynamicGenerationSchema(arrayOf: dynamicSchema(for: items))
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    /// The generated arguments as a JSON string, matching how every other
    /// backend reports them so the transcript reads the same everywhere.
    private static func jsonString(from content: GeneratedContent) -> String {
        let debug = content.debugDescription
        if debug.hasPrefix("{") || debug.hasPrefix("[") { return debug }
        return "{}"
    }
}

/// Apple Foundation Models (on-device AI) service.
///
/// Uses the system `LanguageModelSession` to run inference entirely on-device
/// via Apple Intelligence. The session is created lazily and can be reset to
/// clear conversation context.
///
/// Marked `@unchecked Sendable` because `LanguageModelSession` is not itself
/// `Sendable`, but all access is confined to the `@MainActor` isolation context
/// provided by the project's default actor isolation setting.
@available(macOS 26.0, *)
final class AppleFoundationModelService: AIServiceProtocol, @unchecked Sendable {
    let backendName = "Apple Intelligence"
    let backend: AIBackend = .appleFoundationModels

    private var session: LanguageModelSession?

    init() {
        // Session is created lazily on first use.
    }

    // MARK: - Availability

    func checkAvailability() async -> Bool {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return true
        case .unavailable:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Session Management

    /// Returns the existing session or creates a new one.
    private func getOrCreateSession() -> LanguageModelSession {
        if let session {
            return session
        }
        let newSession = LanguageModelSession()
        self.session = newSession
        return newSession
    }

    /// A session wired to the given tools. Tools are fixed at session
    /// construction, so a turn that offers a different set needs its own
    /// session rather than the cached one.
    private func session(withTools tools: [AITool]) -> (session: LanguageModelSession, bridges: [MCPBridgeTool]) {
        let bridges = tools.compactMap { MCPBridgeTool(tool: $0) }
        guard !bridges.isEmpty else { return (getOrCreateSession(), []) }
        return (LanguageModelSession(tools: bridges), bridges)
    }

    /// Resets the session, clearing all conversation context.
    func resetSession() {
        session = nil
    }

    // MARK: - Streaming Chat

    func streamChat(
        messages: [ChatMessage],
        systemPrompt: String?,
        modelOverride: String?,
        parameters: AIParameters?,
        tools: [AITool]?
    ) -> AsyncThrowingStream<AIStreamChunk, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = self.buildPrompt(from: messages, systemPrompt: systemPrompt)
                    // The framework runs the tool loop itself, so tools are
                    // attached to the session rather than driven by the app's
                    // own loop the way the HTTP backends are.
                    let (session, bridges) = self.session(withTools: tools ?? [])
                    let stream = session.streamResponse(to: prompt)

                    var lastLength = 0
                    for try await partialResponse in stream {
                        if Task.isCancelled { break }

                        let currentText = partialResponse.content
                        if currentText.count > lastLength {
                            let newContent = String(currentText.dropFirst(lastLength))
                            continuation.yield(.text(newContent))
                            lastLength = currentText.count
                        }
                    }

                    // Report whatever the framework ran so the transcript is
                    // populated here too.
                    let runs = bridges.flatMap { $0.drainRuns() }
                    if !runs.isEmpty {
                        continuation.yield(.toolRuns(runs))
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

    // MARK: - Single Generation

    func generateOnce(prompt: String, systemPrompt: String?, modelOverride: String?, parameters: AIParameters?, tools: [AITool]?) async throws -> String {
        let fullPrompt: String
        if let systemPrompt {
            fullPrompt = "\(systemPrompt)\n\n\(prompt)"
        } else {
            fullPrompt = prompt
        }

        let session = getOrCreateSession()
        let response = try await session.respond(to: fullPrompt)
        return response.content
    }

    // MARK: - Helpers

    /// Builds a single prompt string from the conversation history and optional system prompt.
    ///
    /// Apple Foundation Models don't natively support multi-turn chat roles, so
    /// we format the history into a structured text prompt with role labels.
    private func buildPrompt(from messages: [ChatMessage], systemPrompt: String?) -> String {
        var parts: [String] = []

        if let systemPrompt {
            parts.append("[System Instructions]\n\(systemPrompt)")
        }

        for msg in messages {
            switch msg.role {
            case .system:
                parts.append("[System]\n\(msg.content)")
            case .user:
                parts.append("[User]\n\(msg.content)")
            case .assistant:
                parts.append("[Assistant]\n\(msg.content)")
            case .tool:
                // Apple's on-device model has no tool-calling API, so the loop
                // never feeds it tool turns; render defensively as context.
                parts.append("[Tool Result]\n\(msg.content)")
            }
        }

        return parts.joined(separator: "\n\n")
    }
}

#else

// MARK: - Stub for platforms without FoundationModels

/// Placeholder service for platforms where FoundationModels is not available.
///
/// This stub always reports itself as unavailable so the ``AIServiceManager``
/// can gracefully fall back to other backends.
final class AppleFoundationModelService: AIServiceProtocol, @unchecked Sendable {
    let backendName = "Apple Intelligence"
    let backend: AIBackend = .appleFoundationModels

    func checkAvailability() async -> Bool { false }

    func streamChat(
        messages: [ChatMessage],
        systemPrompt: String?,
        modelOverride: String?,
        parameters: AIParameters?,
        tools: [AITool]?
    ) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIServiceError.backendUnavailable("FoundationModels not available")) }
    }

    func generateOnce(prompt: String, systemPrompt: String?, modelOverride: String?, parameters: AIParameters?, tools: [AITool]?) async throws -> String {
        throw AIServiceError.backendUnavailable("FoundationModels not available on this platform")
    }
}

#endif

