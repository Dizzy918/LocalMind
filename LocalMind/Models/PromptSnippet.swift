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

    /// Fills template variables into snippet text on insert:
    /// `{{date}}` → "Jul 19, 2026", `{{time}}` → "9:41 AM",
    /// `{{clipboard}}` → current pasteboard text (empty when unavailable).
    /// Matching is case-insensitive. Date and clipboard are parameters so
    /// the expansion is a pure, testable function.
    static func expandVariables(in text: String, date: Date = Date(), clipboard: String? = nil) -> String {
        guard text.contains("{{") else { return text }
        let replacements: [(pattern: String, value: String)] = [
            ("{{date}}", date.formatted(date: .abbreviated, time: .omitted)),
            ("{{time}}", date.formatted(date: .omitted, time: .shortened)),
            ("{{clipboard}}", clipboard ?? "")
        ]
        var result = text
        for (pattern, value) in replacements {
            while let range = result.range(of: pattern, options: .caseInsensitive) {
                result.replaceSubrange(range, with: value)
            }
        }
        return result
    }
}
