//
//  PerformanceTests.swift
//  LocalMindTests
//
//  Measures the things that scale with a user's history: cold load, memory,
//  and search latency.
//
//  These exist because of a specific trade. The search index used to keep a
//  lowercased copy of every message permanently in memory; removing it halves
//  the footprint but moves work to query time, since matching now scans the
//  live messages. That's only a good trade if search stays fast, so the
//  latency ceiling here is the real assertion — the memory figures are
//  reported for the record.
//
//  Sizes are chosen to represent a heavy user rather than to stress the
//  machine, so the suite stays quick.
//

import XCTest
@testable import LocalMind

final class HistoryScaleTests: XCTestCase {

    // A heavy-but-plausible library: a couple of years of daily use.
    private let conversationCount = 1_500
    private let messagesPerConversation = 12
    /// Roughly a paragraph per message.
    private let messageLength = 480

    private var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindPerf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Deterministic filler that looks like prose, so substring search has to
    /// do real comparisons rather than bailing on the first character.
    private static let vocabulary = [
        "project", "meeting", "deadline", "refactor", "database", "customer",
        "release", "migration", "estimate", "document", "revision", "summary",
        "planning", "incident", "retention", "throughput", "onboarding", "budget"
    ]

    private func filler(seed: Int, length: Int) -> String {
        var words: [String] = []
        var value = seed
        while words.joined(separator: " ").count < length {
            value = (value &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
            words.append(Self.vocabulary[value % Self.vocabulary.count])
        }
        return words.joined(separator: " ")
    }

    private func makeConversations(count: Int) -> [Conversation] {
        (0..<count).map { index in
            var conversation = Conversation(title: "Conversation \(index) \(filler(seed: index, length: 24))")
            for turn in 0..<messagesPerConversation {
                conversation.messages.append(ChatMessage(
                    role: turn.isMultiple(of: 2) ? .user : .assistant,
                    content: filler(seed: index &* 31 &+ turn, length: messageLength)
                ))
            }
            // One needle near the end of the corpus, so a search that finds it
            // has genuinely scanned rather than matched the first record.
            if index == count - 1 {
                conversation.messages.append(ChatMessage(role: .user, content: "the needle is xylophone"))
            }
            return conversation
        }
    }

    /// Resident memory of this process, for before/after deltas.
    private func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private func megabytes(_ bytes: Int) -> Double { Double(bytes) / 1_048_576 }

    // MARK: - Search latency
    //
    // The assertion that matters: removing the index must not have made search
    // sluggish. Ceilings are generous multiples of what a healthy result looks
    // like, so this fails on a regression rather than on a busy CI machine.

    func testSearchLatencyOnLargeHistory() throws {
        let store = DataStore(baseDirectoryOverride: testDir)
        for conversation in makeConversations(count: conversationCount) {
            store.saveConversation(conversation)
        }
        XCTAssertEqual(store.conversations.count, conversationCount)

        // A term that appears nowhere: the worst case, since every message of
        // every conversation must be scanned before concluding "no results".
        let start = Date()
        let misses = store.searchConversations(query: "zzzznotpresent")
        let missSeconds = Date().timeIntervalSince(start)
        XCTAssertTrue(misses.isEmpty)

        // A term that exists only in the last conversation.
        let hitStart = Date()
        let hits = store.searchConversations(query: "xylophone")
        let hitSeconds = Date().timeIntervalSince(hitStart)
        XCTAssertEqual(hits.count, 1)

        print("""
        [scale] \(conversationCount) conversations × \(messagesPerConversation) messages
        [scale] search miss (worst case): \(String(format: "%.1f", missSeconds * 1000)) ms
        [scale] search hit:               \(String(format: "%.1f", hitSeconds * 1000)) ms
        """)

        // Measured baseline on this corpus is ~130ms. The ceiling is set well
        // above it so an ordinary slow machine doesn't fail the suite, but far
        // below the ~2.3s that `range(of:options:)` with diacritic folding
        // costs — the regression this test was written after catching.
        XCTAssertLessThan(missSeconds, 1.0, "worst-case search regressed — check the matching primitive")
        XCTAssertLessThan(hitSeconds, 1.0)
    }

    func testMultiTermSearchStaysFast() throws {
        let store = DataStore(baseDirectoryOverride: testDir)
        for conversation in makeConversations(count: conversationCount) {
            store.saveConversation(conversation)
        }

        // Every term must match, so this is the most work a query can ask for.
        let start = Date()
        _ = store.searchConversations(query: "project meeting deadline refactor")
        let seconds = Date().timeIntervalSince(start)
        print("[scale] four-term search: \(String(format: "%.1f", seconds * 1000)) ms")
        XCTAssertLessThan(seconds, 1.0)
    }

    // MARK: - Memory
    //
    // Reported rather than asserted: resident size is noisy and depends on the
    // allocator, so a hard threshold would be flaky. The comparison between the
    // two numbers is the point.

    func testLegacySearchIndexMemoryCost() throws {
        let conversations = makeConversations(count: conversationCount)

        let before = residentBytes()
        // Exactly what the removed index held: conversation id → lowercased
        // title plus every message, concatenated.
        var legacyIndex: [UUID: String] = [:]
        for conversation in conversations {
            legacyIndex[conversation.id] = ([conversation.title] + conversation.messages.map(\.content))
                .joined(separator: " ")
                .lowercased()
        }
        let after = residentBytes()

        let indexCost = max(0, after - before)
        let corpusChars = conversations.reduce(0) { $0 + $1.messages.reduce(0) { $0 + $1.content.count } }

        print("""
        [scale] corpus text:                 \(String(format: "%.1f", Double(corpusChars) / 1_048_576)) M chars
        [scale] legacy index memory cost:    \(String(format: "%.1f", megabytes(indexCost))) MB
        [scale] (this is what removing it gives back, permanently)
        """)

        XCTAssertEqual(legacyIndex.count, conversationCount, "keeps the index alive until measured")
        XCTAssertGreaterThan(indexCost, 0, "the duplicate copy has a real, non-zero cost")
    }

    // MARK: - Cold load

    func testColdLoadTimeFromDisk() throws {
        // Populate on disk, then load a fresh store the way launch does.
        let writer = DataStore(baseDirectoryOverride: testDir)
        for conversation in makeConversations(count: conversationCount) {
            writer.saveConversation(conversation)
        }

        let start = Date()
        let loaded = DataStore(baseDirectoryOverride: testDir)
        let seconds = Date().timeIntervalSince(start)

        print("[scale] cold load of \(loaded.conversations.count) conversations: \(String(format: "%.0f", seconds * 1000)) ms")

        XCTAssertEqual(loaded.conversations.count, conversationCount)
        // Launch blocks on this, so it's the number that decides whether the
        // JSON-per-conversation store needs replacing with a database.
        XCTAssertLessThan(seconds, 10, "cold load shouldn't dominate launch")
    }
}
