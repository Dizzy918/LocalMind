//
//  RobustnessTests.swift
//  LocalMindTests
//
//  Hostile and degenerate inputs across the data layer.
//
//  The app reads files it wrote on a previous version, text extracted from
//  arbitrary documents, and JSON produced by third-party MCP servers and by
//  models. None of that is guaranteed well-formed, and the failure mode that
//  matters is losing a user's history — so the bias here is "degrade, don't
//  crash, and never silently delete".
//

import XCTest
@testable import LocalMind

final class StoreRobustnessTests: XCTestCase {

    private var testDir: URL!
    private var store: DataStore!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindRobust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        store = DataStore(baseDirectoryOverride: testDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    private var conversationsDir: URL {
        testDir.appendingPathComponent("conversations")
    }

    private func saved(_ title: String, _ text: String) -> Conversation {
        var convo = Conversation(title: title)
        convo.messages.append(ChatMessage(role: .user, content: text))
        store.saveConversation(convo)
        return convo
    }

    // MARK: - Corrupt and unreadable files

    func testCorruptFileDoesNotPreventLoadingTheRest() throws {
        let good = saved("Good", "readable content")

        // A truncated write, the shape a crash mid-save would leave behind.
        try "{ this is not json".write(
            to: conversationsDir.appendingPathComponent("\(UUID().uuidString).json"),
            atomically: true, encoding: .utf8
        )

        let reloaded = DataStore(baseDirectoryOverride: testDir, defaults: store.defaults)
        XCTAssertTrue(reloaded.conversations.contains { $0.id == good.id },
                      "one unreadable file must not cost the user everything else")
    }

    func testEmptyAndStrayFilesAreIgnored() throws {
        let good = saved("Good", "content")
        try Data().write(to: conversationsDir.appendingPathComponent("\(UUID().uuidString).json"))
        try "not ours".write(to: conversationsDir.appendingPathComponent("README.txt"),
                             atomically: true, encoding: .utf8)

        let reloaded = DataStore(baseDirectoryOverride: testDir, defaults: store.defaults)
        XCTAssertTrue(reloaded.conversations.contains { $0.id == good.id })
    }

    func testGarbageGzipIsSkippedNotFatal() throws {
        _ = saved("Good", "content")
        // A .json.gz whose bytes aren't valid zlib.
        try Data([0x1f, 0x8b, 0x00, 0x01, 0x02, 0x03]).write(
            to: conversationsDir.appendingPathComponent("\(UUID().uuidString).json.gz")
        )
        let reloaded = DataStore(baseDirectoryOverride: testDir, defaults: store.defaults)
        XCTAssertEqual(reloaded.conversations.count, 1)
    }

    // MARK: - Large and unusual content

    func testLargeConversationCompressesAndRoundTrips() {
        // Past the 50KB threshold, so it takes the gzip path.
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
        var convo = Conversation(title: "Big")
        for index in 0..<80 {
            convo.messages.append(ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                                              content: paragraph))
        }
        store.saveConversation(convo)

        let reloaded = DataStore(baseDirectoryOverride: testDir, defaults: store.defaults)
        let restored = reloaded.conversations.first { $0.id == convo.id }
        XCTAssertEqual(restored?.messages.count, 80)
        XCTAssertEqual(restored?.messages.last?.content, paragraph, "compression must be lossless")
    }

    func testUnicodeSurvivesAndIsSearchable() {
        let text = "emoji 🧠🚀 · CJK 日本語のテキスト · Cyrillic Привет · RTL مرحبا · combining é vs é"
        let convo = saved("Unicode", text)

        let reloaded = DataStore(baseDirectoryOverride: testDir, defaults: store.defaults)
        XCTAssertEqual(reloaded.conversations.first { $0.id == convo.id }?.messages.first?.content, text)

        XCTAssertFalse(store.searchConversations(query: "日本語").isEmpty)
        XCTAssertFalse(store.searchConversations(query: "Привет").isEmpty)
        XCTAssertFalse(store.searchConversations(query: "🚀").isEmpty)
    }

    func testSearchTermsWithRegexMetacharactersAreLiteral() {
        _ = saved("Regexy", "cost is $5.00 (approx) [see notes] a+b")
        // These must be treated as text, not patterns — and must not throw.
        XCTAssertFalse(store.searchConversations(query: "$5.00").isEmpty)
        XCTAssertFalse(store.searchConversations(query: "(approx)").isEmpty)
        XCTAssertFalse(store.searchConversations(query: "a+b").isEmpty)
        XCTAssertTrue(store.searchConversations(query: ".*").isEmpty, "a wildcard must not match everything")
    }

    func testEmptyAndWhitespaceQueriesReturnNothing() {
        _ = saved("Something", "content")
        XCTAssertTrue(store.searchConversations(query: "").isEmpty)
        XCTAssertTrue(store.searchConversations(query: "   ").isEmpty)
        XCTAssertTrue(store.searchConversations(query: "\n\t").isEmpty)
    }

    // MARK: - Tags

    func testTagsRejectJunkAndDeduplicate() {
        let convo = saved("Tagged", "x")
        store.setTags(["  ", "", "Work", "work", "WORK  ", "  spaced  "], for: convo)
        let stored = store.conversations.first { $0.id == convo.id }
        XCTAssertEqual(stored?.tags, ["work", "spaced"])
    }

    func testTagWithUnicodeIsPreserved() {
        let convo = saved("Tagged", "x")
        store.setTags(["日本語", "🚀launch"], for: convo)
        XCTAssertEqual(store.conversations.first { $0.id == convo.id }?.tags.count, 2)
    }

    // MARK: - Import

    func testImportRejectsGarbageWithoutThrowing() {
        XCTAssertEqual(store.importConversations(from: Data("nonsense".utf8)), 0)
        XCTAssertEqual(store.importConversations(from: Data()), 0)
        XCTAssertEqual(store.importAgents(from: Data("[1,2,3]".utf8)), 0)
        XCTAssertEqual(store.importPipelines(from: Data("{}".utf8)), 0)
    }

    func testImportingTheSameConversationTwiceDoesNotDuplicate() throws {
        var convo = Conversation(title: "Imported")
        convo.messages.append(ChatMessage(role: .user, content: "hello"))
        let data = try JSONEncoder().encode([convo])

        XCTAssertEqual(store.importConversations(from: data), 1)
        let afterFirst = store.conversations.count
        // Re-importing an unchanged export is a no-op, not a second copy.
        _ = store.importConversations(from: data)
        XCTAssertEqual(store.conversations.count, afterFirst)
    }

    // MARK: - Deletion

    func testDeleteRemovesBothPlainAndCompressedFiles() throws {
        let paragraph = String(repeating: "compress me ", count: 6000)
        var convo = Conversation(title: "Big")
        convo.messages.append(ChatMessage(role: .user, content: paragraph))
        store.saveConversation(convo)
        store.deleteConversation(convo)

        let remaining = try FileManager.default.contentsOfDirectory(at: conversationsDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(convo.id.uuidString) }
        XCTAssertTrue(remaining.isEmpty, "neither the .json nor the .json.gz may be left behind")
    }
}

// MARK: - Chunking and retrieval edges

final class RetrievalRobustnessTests: XCTestCase {

    func testChunkerHandlesDegenerateInput() {
        XCTAssertTrue(EmbeddingService.chunk("").isEmpty)
        XCTAssertTrue(EmbeddingService.chunk("   \n\n\t  ").isEmpty)
        XCTAssertEqual(EmbeddingService.chunk("one").count, 1)
    }

    func testChunkerHandlesTextWithNoParagraphBreaks() {
        let wall = String(repeating: "word ", count: 2000)
        let chunks = EmbeddingService.chunk(wall, maxChars: 500, overlapChars: 50)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
    }

    func testChunkerPreservesUnicodeBoundaries() {
        // Slicing by character offsets must not split a grapheme cluster.
        let text = String(repeating: "👨‍👩‍👧‍👦 家族 ", count: 200)
        let chunks = EmbeddingService.chunk(text, maxChars: 120, overlapChars: 20)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.joined().contains("家族"))
    }

    func testStitchUndoesOverlapSoRebuildsDontCompound() {
        let chunks = EmbeddingService.chunk(
            (0..<12).map { "Paragraph number \($0) with some filler text to push length." }.joined(separator: "\n\n"),
            maxChars: 200, overlapChars: 40
        )
        XCTAssertGreaterThan(chunks.count, 1)

        let stitched = KnowledgeBaseStore.stitch(chunks)
        // Re-chunking the stitched text must not grow without bound, which is
        // what happens if the carried context is folded back in each time.
        let rechunked = EmbeddingService.chunk(stitched, maxChars: 200, overlapChars: 40)
        XCTAssertLessThanOrEqual(rechunked.count, chunks.count + 1)
    }

    func testLexicalIndexHandlesEmptyAndSymbolOnlyText() {
        let index = LexicalIndex(documents: [(UUID(), ""), (UUID(), "!!! ??? ***")])
        XCTAssertTrue(index.scores(for: "anything").isEmpty)
    }

    func testLexicalIndexIsCaseInsensitive() {
        let id = UUID()
        let index = LexicalIndex(documents: [(id, "Deployment FAILED with ERROR")])
        XCTAssertNotNil(index.scores(for: "error")[id])
        XCTAssertNotNil(index.scores(for: "ERROR")[id])
    }

    func testCosineHandlesDegenerateVectors() {
        XCTAssertEqual(EmbeddingService.cosineSimilarity([], []), 0)
        XCTAssertEqual(EmbeddingService.cosineSimilarity([0, 0, 0], [1, 1, 1]), 0)
        XCTAssertEqual(EmbeddingService.cosineSimilarity([1, 2], [1, 2, 3]), 0)
    }
}

// MARK: - Message and tool-run edges

final class MessageRobustnessTests: XCTestCase {

    func testToolRunToleratesHostileArguments() {
        // Whatever a model emits, the transcript has to render something and
        // must never crash — malformed JSON falls back to the raw string.
        let hostile = ["", "{", "null", "[]", "\"just a string\"",
                       String(repeating: "{\"a\":", count: 200), "🚀", "{\"a\": NaN}"]
        for arguments in hostile {
            let run = ToolRun(name: "t", arguments: arguments, result: "r")
            let formatted = run.formattedArguments
            if arguments.isEmpty {
                XCTAssertTrue(formatted.isEmpty)
            } else {
                XCTAssertFalse(formatted.isEmpty, "should render something for: \(arguments.prefix(20))")
            }
        }
    }

    func testThinkBlockEdgeCases() {
        XCTAssertEqual("".strippingThinkBlocks, "")
        XCTAssertEqual("<think></think>".strippingThinkBlocks, "")
        XCTAssertEqual("<think>only thinking".strippingThinkBlocks, "")
        XCTAssertEqual("</think>orphan close".strippingThinkBlocks, "</think>orphan close")
        // Nested-looking markers shouldn't lose the answer.
        XCTAssertTrue("<think>a<think>b</think>answer".strippingThinkBlocks.contains("answer"))
    }

    func testContextSelectionAlwaysKeepsTheNewestMessage() {
        let huge = ChatMessage(role: .user, content: String(repeating: "x", count: 100_000))
        let selection = ChatGenerationService.selectContext(messages: [huge], maxMessages: 10, tokenBudget: 10)
        XCTAssertEqual(selection.included.count, 1, "sending nothing is worse than sending one truncated message")
    }

    func testContextSelectionWithNoMessages() {
        let selection = ChatGenerationService.selectContext(messages: [], maxMessages: 10, tokenBudget: 1000)
        XCTAssertTrue(selection.included.isEmpty)
        XCTAssertEqual(selection.excludedCount, 0)
    }

    func testTokenEstimatorHandlesExtremes() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        XCTAssertGreaterThan(TokenEstimator.estimate("🚀🚀🚀"), 0)
        XCTAssertGreaterThan(TokenEstimator.estimate(String(repeating: "a", count: 10_000)), 0)
    }
}
