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

nonisolated struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    var imageData: Data? // Added to support Vision models
    var attachedFileName: String? // e.g. "report.pdf"
    var attachedFileContent: String? // The extracted text from the file, sent to the AI
    let timestamp: Date

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
