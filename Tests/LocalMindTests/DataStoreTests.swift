//
//  DataStoreTests.swift
//  LocalMindTests
//
//  Tests for DataStore persistence, compression, and search.
//

import XCTest
@testable import LocalMind

final class DataStoreTests: XCTestCase {

    var dataStore: DataStore!
    var testDir: URL!

    override func setUp() {
        super.setUp()
        // Fresh isolated temp directory per test, passed explicitly to
        // DataStore via the test-only initializer. Without this, every
        // test run would leak conversations into the user's real
        // Application Support folder.
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        dataStore = DataStore(baseDirectoryOverride: testDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        dataStore = nil
        super.tearDown()
    }

    // MARK: - Save & Load

    func testSaveAndRetrieveConversation() {
        let conversation = Conversation(
            title: "Test Chat",
            messages: [
                ChatMessage(role: .user, content: "Hello"),
                ChatMessage(role: .assistant, content: "Hi there!")
            ]
        )

        dataStore.saveConversation(conversation)

        XCTAssertTrue(dataStore.conversations.contains { $0.id == conversation.id })
        XCTAssertEqual(dataStore.conversations.first { $0.id == conversation.id }?.title, "Test Chat")
    }

    func testSaveUpdatesExistingConversation() {
        var conversation = Conversation(title: "Original")
        conversation.messages.append(ChatMessage(role: .user, content: "Hi"))
        dataStore.saveConversation(conversation)

        conversation.title = "Updated"
        dataStore.saveConversation(conversation)

        let stored = dataStore.conversations.first { $0.id == conversation.id }
        XCTAssertEqual(stored?.title, "Updated")
        XCTAssertEqual(dataStore.conversations.filter { $0.id == conversation.id }.count, 1,
                       "Updating shouldn't create duplicates")
    }

    func testDeleteConversation() {
        let conversation = Conversation(title: "To Delete")
        dataStore.saveConversation(conversation)
        XCTAssertTrue(dataStore.conversations.contains { $0.id == conversation.id })

        dataStore.deleteConversation(conversation)
        XCTAssertFalse(dataStore.conversations.contains { $0.id == conversation.id })
    }

    // MARK: - Search

    func testSearchMatchesTitleWord() {
        var conversation = Conversation(title: "Python Tutorial")
        conversation.messages.append(ChatMessage(role: .user, content: "Hello"))
        dataStore.saveConversation(conversation)

        let results = dataStore.searchConversations(query: "python")
        XCTAssertTrue(results.contains { $0.id == conversation.id })
    }

    func testSearchMatchesMessageContent() {
        var conversation = Conversation(title: "General Chat")
        conversation.messages.append(ChatMessage(role: .user, content: "Tell me about turtles"))
        conversation.messages.append(ChatMessage(role: .assistant, content: "Turtles are reptiles"))
        dataStore.saveConversation(conversation)

        let results = dataStore.searchConversations(query: "turtle")
        XCTAssertTrue(results.contains { $0.id == conversation.id },
                      "Search should find content in messages, not just titles")
    }

    func testSearchMultiWordRequiresAllTerms() {
        var conversation = Conversation(title: "Python Help")
        conversation.messages.append(ChatMessage(role: .user, content: "How do I sort a list?"))
        dataStore.saveConversation(conversation)

        let bothMatch = dataStore.searchConversations(query: "python sort")
        let oneMissing = dataStore.searchConversations(query: "python javascript")

        XCTAssertTrue(bothMatch.contains { $0.id == conversation.id })
        XCTAssertFalse(oneMissing.contains { $0.id == conversation.id })
    }

    func testSearchIsCaseInsensitive() {
        var conversation = Conversation(title: "Coffee Shop")
        conversation.messages.append(ChatMessage(role: .user, content: "Hi"))
        dataStore.saveConversation(conversation)

        XCTAssertTrue(dataStore.searchConversations(query: "COFFEE").contains { $0.id == conversation.id })
        XCTAssertTrue(dataStore.searchConversations(query: "coffee").contains { $0.id == conversation.id })
        XCTAssertTrue(dataStore.searchConversations(query: "CoFfEe").contains { $0.id == conversation.id })
    }

    func testSearchEmptyQueryReturnsEmpty() {
        var conversation = Conversation(title: "Anything")
        conversation.messages.append(ChatMessage(role: .user, content: "Anything"))
        dataStore.saveConversation(conversation)

        XCTAssertEqual(dataStore.searchConversations(query: "").count, 0)
        XCTAssertEqual(dataStore.searchConversations(query: "   ").count, 0)
    }

    func testSearchIsScopedToActiveProfile() {
        // saveConversation stamps the active profile (read from UserDefaults)
        // onto new conversations, and search must only return the active
        // profile's matches. Save/restore the real key so we don't disturb
        // the host app's state.
        let key = "activeProfileID"
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let profileA = UUID()
        let profileB = UUID()

        UserDefaults.standard.set(profileA.uuidString, forKey: key)
        var convoA = Conversation(title: "A chat")
        convoA.messages.append(ChatMessage(role: .user, content: "alpha secret"))
        dataStore.saveConversation(convoA)

        UserDefaults.standard.set(profileB.uuidString, forKey: key)
        var convoB = Conversation(title: "B chat")
        convoB.messages.append(ChatMessage(role: .user, content: "beta secret"))
        dataStore.saveConversation(convoB)

        // Active profile is B: searching for A's word must return nothing.
        XCTAssertTrue(dataStore.searchConversations(query: "alpha").isEmpty,
                      "Profile B must not see profile A's conversations in search")
        XCTAssertTrue(dataStore.searchConversations(query: "beta").contains { $0.id == convoB.id })

        // Switch to A: now A's word matches and B's does not.
        UserDefaults.standard.set(profileA.uuidString, forKey: key)
        XCTAssertTrue(dataStore.searchConversations(query: "alpha").contains { $0.id == convoA.id })
        XCTAssertTrue(dataStore.searchConversations(query: "beta").isEmpty,
                      "Profile A must not see profile B's conversations in search")
    }

    func testSearchAfterDeleteDoesNotMatch() {
        var conversation = Conversation(title: "Lemon Cake Recipe")
        conversation.messages.append(ChatMessage(role: .user, content: "Hi"))
        dataStore.saveConversation(conversation)

        XCTAssertTrue(dataStore.searchConversations(query: "lemon").contains { $0.id == conversation.id })

        dataStore.deleteConversation(conversation)
        XCTAssertFalse(dataStore.searchConversations(query: "lemon").contains { $0.id == conversation.id })
    }

    // MARK: - Sorting

    func testConversationsForSelectionExcludesEmptyMessages() {
        let emptyConversation = Conversation(title: "Empty")
        var fullConversation = Conversation(title: "Full")
        fullConversation.messages.append(ChatMessage(role: .user, content: "Hi"))

        dataStore.saveConversation(emptyConversation)
        dataStore.saveConversation(fullConversation)

        let visible = dataStore.conversationsForSelection(.chat)
        XCTAssertTrue(visible.contains { $0.id == fullConversation.id })
        XCTAssertFalse(visible.contains { $0.id == emptyConversation.id },
                       "Empty conversations shouldn't appear in the sidebar")
    }

    func testConversationsSortedByUpdatedAt() {
        var older = Conversation(title: "Older")
        older.messages.append(ChatMessage(role: .user, content: "Hi"))
        older.updatedAt = Date(timeIntervalSinceNow: -3600)

        var newer = Conversation(title: "Newer")
        newer.messages.append(ChatMessage(role: .user, content: "Hi"))
        newer.updatedAt = Date()

        dataStore.saveConversation(older)
        dataStore.saveConversation(newer)

        let visible = dataStore.conversationsForSelection(.chat)
        let olderIndex = visible.firstIndex { $0.id == older.id }
        let newerIndex = visible.firstIndex { $0.id == newer.id }

        XCTAssertNotNil(olderIndex)
        XCTAssertNotNil(newerIndex)
        XCTAssertLessThan(newerIndex!, olderIndex!, "Newer conversations should sort first")
    }
}
