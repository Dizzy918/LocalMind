//
//  ConversationTests.swift
//  LocalMindTests
//
//  Tests for Conversation and ChatMessage model logic.
//

import XCTest
@testable import LocalMind

final class ConversationTests: XCTestCase {

    func testNewConversationHasDefaults() {
        let conversation = Conversation()
        XCTAssertEqual(conversation.title, "New Conversation")
        XCTAssertEqual(conversation.toolType, .chat)
        XCTAssertNil(conversation.emoji)
        XCTAssertNil(conversation.customToolID)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertEqual(conversation.createdAt, conversation.updatedAt)
    }

    func testUpdateTitleIfNeededUsesFirstUserMessage() {
        var conversation = Conversation()
        conversation.messages.append(ChatMessage(role: .user, content: "How do I deploy a Vapor app?"))
        conversation.updateTitleIfNeeded()

        XCTAssertEqual(conversation.title, "How do I deploy a Vapor app?")
    }

    func testUpdateTitleIfNeededTruncatesLongMessages() {
        var conversation = Conversation()
        let longContent = String(repeating: "a", count: 100)
        conversation.messages.append(ChatMessage(role: .user, content: longContent))
        conversation.updateTitleIfNeeded()

        XCTAssertTrue(conversation.title.hasSuffix("..."))
        XCTAssertLessThanOrEqual(conversation.title.count, 53)
    }

    func testUpdateTitleIfNeededIgnoresAlreadyTitled() {
        var conversation = Conversation(title: "Custom Title")
        conversation.messages.append(ChatMessage(role: .user, content: "Other content"))
        conversation.updateTitleIfNeeded()

        XCTAssertEqual(conversation.title, "Custom Title",
                       "Should not overwrite an already-set custom title")
    }

    func testUpdateTitleIfNeededSkipsAssistantOnly() {
        var conversation = Conversation()
        conversation.messages.append(ChatMessage(role: .assistant, content: "Hello!"))
        conversation.updateTitleIfNeeded()

        XCTAssertEqual(conversation.title, "New Conversation",
                       "Should not generate title from assistant-only messages")
    }

    func testDisplayEmojiFallsBackToToolEmoji() {
        let conversation = Conversation(toolType: .chat)
        XCTAssertEqual(conversation.displayEmoji, ToolType.chat.emoji)
    }

    func testDisplayEmojiPrefersCustomEmoji() {
        let conversation = Conversation(emoji: "🎨")
        XCTAssertEqual(conversation.displayEmoji, "🎨")
    }

    // MARK: - Codable Round-Trip

    func testConversationEncodingRoundTrip() throws {
        var original = Conversation(
            title: "Round Trip Test",
            messages: [
                ChatMessage(role: .user, content: "Hello"),
                ChatMessage(role: .assistant, content: "World")
            ],
            emoji: "🚀"
        )
        original.updatedAt = Date()

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.emoji, original.emoji)
        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.messages[0].content, "Hello")
        XCTAssertEqual(decoded.messages[1].content, "World")
    }

    func testToolTypeGracefulFallbackOnUnknownValue() throws {
        // Simulate an old JSON file that referenced a removed tool type (e.g. "Summarizer")
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Old Conversation",
            "messages": [],
            "toolType": "Summarizer",
            "createdAt": 0,
            "updatedAt": 0
        }
        """.data(using: .utf8)!

        let conversation = try JSONDecoder().decode(Conversation.self, from: json)
        XCTAssertEqual(conversation.toolType, .chat,
                       "Unknown tool types should gracefully convert to .chat")
    }

    // MARK: - ChatMessage

    func testChatMessageEncodingPreservesAllFields() throws {
        let original = ChatMessage(
            role: .user,
            content: "Look at this",
            imageData: Data([0x01, 0x02, 0x03]),
            attachedFileName: "report.pdf",
            attachedFileContent: "PDF contents here"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.content, "Look at this")
        XCTAssertEqual(decoded.imageData, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(decoded.attachedFileName, "report.pdf")
        XCTAssertEqual(decoded.attachedFileContent, "PDF contents here")
    }
}
