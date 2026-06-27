//
//  AppleFoundationModelService.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

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
                    let session = self.getOrCreateSession()
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

