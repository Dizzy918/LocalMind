//
//  ChatMessage.swift
//  LocalAIHelper
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation

nonisolated enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    /// A tool's result, fed back to the model so it can answer using the
    /// output. Only used inside a single generation's working message list —
    /// tool turns are never persisted into a conversation's history.
    case tool
}

/// A tool the model ran while producing an answer, kept on the message so the
/// transcript survives a relaunch. MCPService's audit log covers the same
/// ground but is session-only and lives in Settings — this is what the chat
/// itself can show, in context, next to the answer the tool produced.
nonisolated struct ToolRun: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    /// Arguments exactly as the model emitted them (a JSON string).
    let arguments: String
    let result: String
    let isError: Bool
    /// Wall-clock time the call took, when measured.
    let seconds: Double?

    init(
        id: UUID = UUID(),
        name: String,
        arguments: String,
        result: String,
        isError: Bool = false,
        seconds: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.seconds = seconds
    }

    /// Arguments pretty-printed for display, falling back to the raw string
    /// when the model emitted something that isn't valid JSON.
    var formattedArguments: String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return arguments
        }
        return text
    }
}

/// A knowledge-base passage an answer was grounded in (RAG citation).
nonisolated struct MessageSource: Codable, Identifiable, Sendable {
    let id: UUID
    let documentName: String
    let snippet: String

    init(id: UUID = UUID(), documentName: String, snippet: String) {
        self.id = id
        self.documentName = documentName
        self.snippet = snippet
    }
}

nonisolated struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    var imageData: Data? // Added to support Vision models
    var attachedFileName: String? // e.g. "report.pdf"
    var attachedFileContent: String? // The extracted text from the file, sent to the AI
    let timestamp: Date

    /// Knowledge-base passages this answer cited (RAG). nil/empty = none.
    var sources: [MessageSource]?
    /// Alternative generations for this turn. When present, `content` mirrors
    /// `variants[activeVariantIndex]`; nil/≤1 means a single answer.
    var variants: [String]?
    var activeVariantIndex: Int?

    // Attribution: which persona/model produced an assistant message. Shown
    // as a small caption on the bubble so multi-agent chats stay legible.
    var agentName: String?
    var agentEmoji: String?
    var modelUsed: String?

    /// The model's chain-of-thought (<think> blocks), kept separate from the
    /// answer and shown in a collapsed disclosure. nil = no reasoning emitted.
    var reasoning: String?

    /// Tool calls the model requested on this assistant turn. Populated only on
    /// the ephemeral assistant messages the tool loop feeds back to the model;
    /// never set on persisted messages.
    var toolCalls: [AIToolCall]?
    /// Tools that ran while producing this answer, with their results. Persisted
    /// — this is the durable transcript the bubble renders.
    var toolRuns: [ToolRun]?
    /// For `.tool` messages, the id of the tool call this result answers, so
    /// OpenAI-compatible servers can correlate result → call.
    var toolCallID: String?

    // Performance stats for assistant messages.
    var generationSeconds: Double?
    var tokensPerSecond: Double?
    /// Token counts as reported by the backend. nil means the backend didn't
    /// say, and any displayed count is TokenEstimator's approximation.
    var promptTokens: Int?
    var completionTokens: Int?

    /// Whether the stats came from the backend rather than being estimated —
    /// lets the UI avoid presenting a guess as though it were measured.
    var hasMeasuredTokens: Bool { completionTokens != nil }

    init(id: UUID = UUID(), role: MessageRole, content: String, imageData: Data? = nil, attachedFileName: String? = nil, attachedFileContent: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.imageData = imageData
        self.attachedFileName = attachedFileName
        self.attachedFileContent = attachedFileContent
        self.timestamp = timestamp
    }
}

extension String {
    /// Splits `<think>…</think>` reasoning blocks (emitted inline by thinking
    /// models like qwen3 and deepseek-r1) away from the visible answer.
    ///
    /// Returns the joined contents of all think blocks as `reasoning` (nil if
    /// none) and everything outside them as `answer`. An unterminated
    /// `<think>` counts its tail as reasoning — that's the live-streaming
    /// state while the model is still thinking.
    var separatingThinkBlocks: (reasoning: String?, answer: String) {
        guard contains("<think>") else { return (nil, self) }
        var answer = ""
        var reasoningParts: [String] = []
        var rest = self[...]
        while let open = rest.range(of: "<think>") {
            answer += rest[rest.startIndex..<open.lowerBound]
            if let close = rest.range(of: "</think>", range: open.upperBound..<rest.endIndex) {
                reasoningParts.append(String(rest[open.upperBound..<close.lowerBound]))
                rest = rest[close.upperBound...]
            } else {
                reasoningParts.append(String(rest[open.upperBound...]))
                rest = rest[rest.endIndex...]
                break
            }
        }
        answer += rest
        let reasoning = reasoningParts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (reasoning.isEmpty ? nil : reasoning,
                answer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The visible answer with all reasoning blocks removed.
    var strippingThinkBlocks: String {
        separatingThinkBlocks.answer
    }
}
