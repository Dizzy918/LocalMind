//
//  PromptSnippet.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import Foundation

/// A saved prompt the user can insert into the input with one click —
/// the "prompt library" behind the book button in the chat input bar.
nonisolated struct PromptSnippet: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var title: String
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), title: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
    }
}
