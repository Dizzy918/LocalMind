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

    // MARK: - Merge

    func testMergeConversationOrdersMessagesByTimestamp() {
        // Source is the OLDER conversation — its messages must interleave
        // before the target's, not get appended after them.
        let earlier = Date(timeIntervalSinceNow: -3600)
        let source = Conversation(
            title: "Old chat",
            messages: [
                ChatMessage(role: .user, content: "first ever", timestamp: earlier),
                ChatMessage(role: .assistant, content: "reply to first", timestamp: earlier.addingTimeInterval(10))
            ]
        )
        let target = Conversation(
            title: "New chat",
            messages: [
                ChatMessage(role: .user, content: "newer message", timestamp: Date())
            ]
        )
        dataStore.saveConversation(source)
        dataStore.saveConversation(target)

        dataStore.mergeConversation(source, into: target)

        let merged = dataStore.conversations.first { $0.id == target.id }!
        XCTAssertEqual(merged.messages.map(\.content), ["first ever", "reply to first", "newer message"])
        XCTAssertFalse(dataStore.conversations.contains { $0.id == source.id })
    }

    // MARK: - Compression round-trip

    func testLargeConversationSurvivesCompressionRoundTrip() {
        // >50KB of message content forces the gzip path on save; reloading
        // exercises decompression (including the growing-buffer logic).
        let bigText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3000)
        let conversation = Conversation(
            title: "Huge",
            messages: [
                ChatMessage(role: .user, content: bigText),
                ChatMessage(role: .assistant, content: bigText)
            ]
        )
        dataStore.saveConversation(conversation)

        let reloaded = DataStore(baseDirectoryOverride: testDir)
        let loaded = reloaded.conversations.first { $0.id == conversation.id }
        XCTAssertEqual(loaded?.messages.count, 2)
        XCTAssertEqual(loaded?.messages.first?.content, bigText)
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

    // MARK: - Tags

    private func savedConversation(_ title: String, text: String = "hello") -> Conversation {
        var convo = Conversation(title: title)
        convo.messages.append(ChatMessage(role: .user, content: text))
        dataStore.saveConversation(convo)
        return dataStore.conversations.first { $0.id == convo.id }!
    }

    func testTagsAreNormalisedOnWrite() {
        let convo = savedConversation("Tagged")
        dataStore.setTags(["  Work ", "WORK", "urgent", ""], for: convo)

        let stored = dataStore.conversations.first { $0.id == convo.id }
        // Case and whitespace variants are one tag, not three that look alike.
        XCTAssertEqual(stored?.tags, ["work", "urgent"])
    }

    func testAddAndRemoveTag() {
        var convo = savedConversation("Tagged")
        dataStore.addTag("Research", to: convo)
        convo = dataStore.conversations.first { $0.id == convo.id }!
        XCTAssertEqual(convo.tags, ["research"])

        dataStore.removeTag("RESEARCH", from: convo)
        XCTAssertEqual(dataStore.conversations.first { $0.id == convo.id }?.tags, [])
    }

    func testFilteringBySelectionAndTag() {
        let tagged = savedConversation("Has tag")
        _ = savedConversation("No tag")
        dataStore.addTag("work", to: tagged)

        let all = dataStore.conversationsForSelection(.chat)
        let filtered = dataStore.conversationsForSelection(.chat, tag: "work")
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(filtered.map(\.id), [tagged.id])
    }

    func testDeletingATagRemovesItEverywhere() {
        let first = savedConversation("One")
        let second = savedConversation("Two")
        dataStore.addTag("temp", to: first)
        dataStore.addTag("temp", to: second)
        XCTAssertEqual(dataStore.allTags, ["temp"])

        dataStore.deleteTagEverywhere("temp")
        XCTAssertTrue(dataStore.allTags.isEmpty)
        XCTAssertTrue(dataStore.conversations.allSatisfy { $0.tags.isEmpty })
    }

    func testTagsSurviveAReload() {
        let convo = savedConversation("Persisted")
        dataStore.setTags(["keepme"], for: convo)

        let reloaded = DataStore(baseDirectoryOverride: testDir, defaults: dataStore.defaults)
        XCTAssertEqual(reloaded.conversations.first { $0.id == convo.id }?.tags, ["keepme"])
    }

    func testLegacyConversationWithoutTagsDecodes() throws {
        // Files written before tags existed must still load.
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","messages":[],"toolType":"chat",
         "createdAt":0,"updatedAt":0}
        """
        let convo = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertTrue(convo.tags.isEmpty)
    }

    // MARK: - Search

    func testSearchMatchesCaseInsensitiveSubstrings() {
        var convo = Conversation(title: "Swift notes")
        convo.messages.append(ChatMessage(role: .user, content: "Investigating CONCURRENCY today"))
        dataStore.saveConversation(convo)

        // Substring, not whole-word, and case-insensitive — the behaviour the
        // removed lowercased index used to provide.
        XCTAssertFalse(dataStore.searchConversations(query: "concur").isEmpty)
        XCTAssertFalse(dataStore.searchConversations(query: "SWIFT").isEmpty)
        XCTAssertTrue(dataStore.searchConversations(query: "kotlin").isEmpty)
    }

    func testSearchIsCaseInsensitiveButNotAccentFolding() {
        var convo = Conversation(title: "Trip notes")
        convo.messages.append(ChatMessage(role: .user, content: "lunch at the café"))
        dataStore.saveConversation(convo)

        XCTAssertFalse(dataStore.searchConversations(query: "CAFÉ").isEmpty, "case is folded")
        // Accent folding is deliberately not done: it costs ~16x in the search
        // primitive, and the app never had it — the old lowercased index didn't
        // fold accents either. Pinned so it's a decision, not a silent drift.
        XCTAssertTrue(dataStore.searchConversations(query: "cafe").isEmpty)
    }

    func testSearchRequiresEveryTerm() {
        var convo = Conversation(title: "Trip")
        convo.messages.append(ChatMessage(role: .user, content: "flights to Lisbon"))
        dataStore.saveConversation(convo)

        XCTAssertFalse(dataStore.searchConversations(query: "flights Lisbon").isEmpty)
        XCTAssertTrue(dataStore.searchConversations(query: "flights Berlin").isEmpty)
    }

    func testSearchFindsEditedContentImmediately() {
        // The old index was updated on save; searching live means an edit can
        // never leave a stale entry behind.
        var convo = Conversation(title: "Draft")
        convo.messages.append(ChatMessage(role: .user, content: "original wording"))
        dataStore.saveConversation(convo)

        convo = dataStore.conversations.first { $0.id == convo.id }!
        convo.messages[0].content = "replacement wording"
        dataStore.saveConversation(convo)

        XCTAssertTrue(dataStore.searchConversations(query: "original").isEmpty)
        XCTAssertFalse(dataStore.searchConversations(query: "replacement").isEmpty)
    }

    func testSearchIsScopedToActiveProfile() {
        // saveConversation stamps the active profile (read from the store's
        // injected defaults) onto new conversations, and search must only
        // return the active profile's matches. The store uses its own isolated
        // suite, so writing the key here can't be polluted by — or pollute —
        // another parallel test process.
        let key = "activeProfileID"
        let defaults = dataStore.defaults

        let profileA = UUID()
        let profileB = UUID()

        defaults.set(profileA.uuidString, forKey: key)
        var convoA = Conversation(title: "A chat")
        convoA.messages.append(ChatMessage(role: .user, content: "alpha secret"))
        dataStore.saveConversation(convoA)

        defaults.set(profileB.uuidString, forKey: key)
        var convoB = Conversation(title: "B chat")
        convoB.messages.append(ChatMessage(role: .user, content: "beta secret"))
        dataStore.saveConversation(convoB)

        // Active profile is B: searching for A's word must return nothing.
        XCTAssertTrue(dataStore.searchConversations(query: "alpha").isEmpty,
                      "Profile B must not see profile A's conversations in search")
        XCTAssertTrue(dataStore.searchConversations(query: "beta").contains { $0.id == convoB.id })

        // Switch to A: now A's word matches and B's does not.
        defaults.set(profileA.uuidString, forKey: key)
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
