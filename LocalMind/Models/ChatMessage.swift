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
