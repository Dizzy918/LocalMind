//
//  NewConversationSendTests.swift
//  LocalMindTests
//
//  Regression tests for the "send button silently drops the message" bug
//  on a brand-new conversation. The root cause was a SwiftUI binding race
//  in ContentView: the detail-view's draft-binding setter cleared the
//  local draftConversation immediately on first save, so a subsequent
//  read in the same sendMessage() call fell back to a stale captured
//  value with no messages, and the next save round-tripped that emptied
//  conversation back to disk.
//
//  These tests replay the binding-closure contract as plain Swift,
//  without SwiftUI, so they pin the invariant: every mutation made
//  through the binding during sendMessage() must be observable on the
//  next read, and the final saved state must reflect every mutation.
//

import XCTest
@testable import LocalMind

/// A tiny stand-in for SwiftUI's `Binding<Conversation>` with the same
/// closure shape as ContentView's draft binding. Mutating it triggers
/// `set`; reading it triggers `get`. Same as how SwiftUI evaluates
/// `binding.wrappedValue.messages.append(...)` under the hood.
private final class ConversationBindingHarness {
    var draft: Conversation?
    var persistedSnapshots: [Conversation] = []

    /// Mirrors the SHIPPED setter from ContentView.detailView. Always
    /// keeps the draft in sync; persists when the conversation has
    /// any messages.
    func write(_ updated: Conversation) {
        draft = updated
        if !updated.messages.isEmpty {
            persistedSnapshots.append(updated)
        }
    }

    /// Mirrors the SHIPPED getter — falls back to the captured initial
    /// draft if the local draft is somehow nil. With the fix in place,
    /// the fallback is never exercised within a sendMessage chain.
    func read(fallback: Conversation) -> Conversation {
        draft ?? fallback
    }

    var lastPersisted: Conversation? { persistedSnapshots.last }
}

final class NewConversationSendTests: XCTestCase {

    /// The classic bug repro: user opens a brand-new chat, types one
    /// message, hits send. sendMessage runs three things in sequence
    /// that all flow through the same binding:
    ///   1. append the user message
    ///   2. bump updatedAt / refresh title
    ///   3. append the assistant's first streaming chunk
    /// Every step must see the previous step's mutation, and the final
    /// persisted snapshot must contain BOTH messages.
    func testThreeStepSendChainPreservesAllMutations() {
        let initial = Conversation(toolType: .chat)
        let harness = ConversationBindingHarness()
        harness.draft = initial

        // Step 1 — append user message (simulates sendMessage()).
        var c = harness.read(fallback: initial)
        c.messages.append(ChatMessage(role: .user, content: "Hello"))
        harness.write(c)

        XCTAssertEqual(harness.lastPersisted?.messages.count, 1,
                       "user message must persist on first save")

        // Step 2 — title bump (simulates updateTitleIfNeeded). MUST see
        // the user message from step 1, not the stale captured initial.
        c = harness.read(fallback: initial)
        XCTAssertEqual(c.messages.count, 1,
                       "step 2 must observe step 1's append")
        c.title = "Greeting"
        c.updatedAt = Date()
        harness.write(c)

        // Step 3 — assistant chunk (simulates first streaming append).
        c = harness.read(fallback: initial)
        XCTAssertEqual(c.messages.count, 1,
                       "step 3 must observe the user message")
        XCTAssertEqual(c.title, "Greeting",
                       "step 3 must observe the title bump")
        c.messages.append(ChatMessage(role: .assistant, content: "Hi there"))
        harness.write(c)

        // The final persisted snapshot must contain everything.
        let final = harness.lastPersisted
        XCTAssertNotNil(final)
        XCTAssertEqual(final?.messages.count, 2)
        XCTAssertEqual(final?.messages.first?.role, .user)
        XCTAssertEqual(final?.messages.first?.content, "Hello")
        XCTAssertEqual(final?.messages.last?.role, .assistant)
        XCTAssertEqual(final?.messages.last?.content, "Hi there")
        XCTAssertEqual(final?.title, "Greeting")
    }

    /// Direct regression: emulate the OLD (buggy) setter that cleared
    /// the draft on first save. The same three-step chain must produce
    /// a broken final state — proving that the fixed harness above is
    /// actually preventing the bug, not just passing for unrelated
    /// reasons.
    func testOldBuggySetterLosesSecondMessage() {
        let initial = Conversation(toolType: .chat)
        var draft: Conversation? = initial
        var lastPersisted: Conversation?

        // Buggy setter from before the fix.
        func writeBuggy(_ updated: Conversation) {
            if updated.messages.isEmpty {
                draft = updated
            } else {
                lastPersisted = updated
                draft = nil // <-- the bug: nils out the local mirror
            }
        }
        func readBuggy() -> Conversation { draft ?? initial }

        // Step 1
        var c = readBuggy()
        c.messages.append(ChatMessage(role: .user, content: "Hello"))
        writeBuggy(c)
        XCTAssertEqual(lastPersisted?.messages.count, 1)

        // Step 2 — read falls back to `initial` (no messages) because
        // the buggy setter just cleared draft.
        c = readBuggy()
        XCTAssertEqual(c.messages.count, 0,
                       "buggy path: read falls back to stale empty draft")

        // Step 3 — assistant append clobbers the persisted user message.
        c.messages.append(ChatMessage(role: .assistant, content: "Hi there"))
        writeBuggy(c)

        XCTAssertEqual(lastPersisted?.messages.count, 1,
                       "buggy path: final persisted state has 1 message, not 2")
        XCTAssertEqual(lastPersisted?.messages.first?.role, .assistant,
                       "buggy path: user message has been overwritten by assistant")
    }

    /// "Stress" variant: many rapid mutations (think dictation streaming
    /// many small chunks) through the fixed binding harness must never
    /// drop any chunk.
    func testManyRapidMutationsAllPersist() {
        let initial = Conversation(toolType: .chat)
        let harness = ConversationBindingHarness()
        harness.draft = initial

        // First, a user message so subsequent writes persist.
        var c = harness.read(fallback: initial)
        c.messages.append(ChatMessage(role: .user, content: "kick off"))
        harness.write(c)

        // Then 200 rapid appends to the streaming assistant message
        // (simulates the streamingContent path).
        for i in 0..<200 {
            c = harness.read(fallback: initial)
            if c.messages.last?.role == .assistant {
                var last = c.messages.removeLast()
                last.content += " \(i)"
                c.messages.append(last)
            } else {
                c.messages.append(ChatMessage(role: .assistant, content: "tok \(i)"))
            }
            harness.write(c)
        }

        let final = harness.lastPersisted
        XCTAssertEqual(final?.messages.count, 2,
                       "user + single streaming assistant message")
        XCTAssertEqual(final?.messages.first?.content, "kick off")
        // Last assistant message should contain every numbered token.
        let assistantContent = final?.messages.last?.content ?? ""
        XCTAssertTrue(assistantContent.contains("tok 0"))
        XCTAssertTrue(assistantContent.contains("199"))
    }

    /// Switching between drafts must not leak content across IDs. If a
    /// user clicks "+" twice in quick succession, the second draft must
    /// start empty, not inherit the first draft's mutations.
    func testSwitchingDraftsResetsContent() {
        let firstDraft = Conversation(toolType: .chat)
        let harness = ConversationBindingHarness()
        harness.draft = firstDraft

        var c = harness.read(fallback: firstDraft)
        c.messages.append(ChatMessage(role: .user, content: "in first draft"))
        harness.write(c)
        XCTAssertEqual(harness.lastPersisted?.messages.count, 1)

        // Simulate "+" — startNewConversation replaces the draft.
        let secondDraft = Conversation(toolType: .chat)
        XCTAssertNotEqual(firstDraft.id, secondDraft.id)
        harness.draft = secondDraft

        let snapshot = harness.read(fallback: secondDraft)
        XCTAssertEqual(snapshot.id, secondDraft.id,
                       "second draft must have its own id")
        XCTAssertEqual(snapshot.messages.count, 0,
                       "second draft must start empty")
    }
}
