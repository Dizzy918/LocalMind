//
//  ChatMemoryStore.swift
//  LocalMind
//
//  On-device memory across conversations. Past exchanges are embedded with
//  Apple's NaturalLanguage vectors and recalled by similarity when a new
//  message arrives, so the assistant can say "we discussed this last week".
//  Opt-in ("rememberPastChats"), stored locally in chat_memory.json.
//

import Foundation

nonisolated struct ChatMemoryEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let conversationID: UUID
    var title: String
    let text: String
    let embedding: [Double]
    let updatedAt: Date
}

nonisolated struct ChatMemoryHit: Sendable {
    let title: String
    let text: String
    let date: Date
}

private struct ChatMemoryArchive: Codable {
    var entries: [ChatMemoryEntry]
    var indexedExchangeCounts: [UUID: Int]
    /// Signature of the already-indexed exchange prefix per conversation, so an
    /// edit to an earlier turn (which changes the text but not the count) is
    /// detected and re-embedded. Optional so archives written before this
    /// field decode cleanly.
    var contentSignatures: [UUID: Int]?
}

@Observable
@MainActor
final class ChatMemoryStore {
    static let shared = ChatMemoryStore()

    private(set) var entries: [ChatMemoryEntry] = []
    /// How many exchanges of each conversation are already indexed, so
    /// re-indexing after a new turn only embeds the delta.
    private var indexedExchangeCounts: [UUID: Int] = [:]
    /// Signature of the indexed exchange prefix per conversation — lets us tell
    /// an *edit* to an old turn apart from an *append* of a new one.
    private var contentSignatures: [UUID: Int] = [:]
    private let fileURL: URL

    /// Uses Apple embeddings unconditionally: always available, on-device,
    /// and immune to the knowledge base's provider lock.
    private let provider = AppleEmbeddingProvider()

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "rememberPastChats")
    }

    init(fileURLOverride: URL? = nil) {
        if let fileURLOverride {
            fileURL = fileURLOverride
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalMind", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("chat_memory.json")
        }
        load()
    }

    var entryCount: Int { entries.count }

    // MARK: - Indexing

    /// Indexes any exchanges of this conversation that aren't embedded yet.
    /// Cheap when nothing changed; call after every completed generation.
    func indexConversation(_ conversation: Conversation) async {
        guard Self.isEnabled else { return }
        let exchanges = Self.exchanges(from: conversation.messages)
        var alreadyIndexed = indexedExchangeCounts[conversation.id] ?? 0

        // If the already-indexed portion changed (an edited/re-rolled earlier
        // turn), its old vectors are stale — drop them and re-embed from
        // scratch. A pure append leaves the prefix signature untouched.
        let priorPrefixSignature = Self.signature(of: exchanges.prefix(alreadyIndexed))
        if alreadyIndexed > 0, let stored = contentSignatures[conversation.id], stored != priorPrefixSignature {
            entries.removeAll { $0.conversationID == conversation.id }
            alreadyIndexed = 0
        }

        guard exchanges.count > alreadyIndexed else {
            // Nothing new to embed. Still refresh the title — it's AI-generated
            // shortly after the first exchange, and recalled snippets should
            // show the real one — and persist if anything actually changed.
            let titleChanged = refreshTitle(conversation)
            let newSignature = Self.signature(of: exchanges[...])
            let signatureChanged = contentSignatures[conversation.id] != newSignature
            contentSignatures[conversation.id] = newSignature
            indexedExchangeCounts[conversation.id] = exchanges.count
            if titleChanged || signatureChanged { save() }
            return
        }
        guard await provider.probe() else { return }

        for exchange in exchanges[alreadyIndexed...] {
            guard let embedding = await provider.embed(exchange) else { continue }
            entries.append(ChatMemoryEntry(
                id: UUID(),
                conversationID: conversation.id,
                title: conversation.title,
                text: exchange,
                embedding: embedding,
                updatedAt: conversation.updatedAt
            ))
        }
        indexedExchangeCounts[conversation.id] = exchanges.count
        contentSignatures[conversation.id] = Self.signature(of: exchanges[...])
        refreshTitle(conversation)
        save()
    }

    /// Order-sensitive, launch-stable signature of a run of exchanges (FNV-1a).
    /// Swift's `hashValue` is per-process randomized, so it can't be persisted
    /// and compared across launches — this can.
    private static func signature<S: Sequence>(of exchanges: S) -> Int where S.Element == String {
        var hash: UInt64 = 1469598103934665603
        for exchange in exchanges {
            for byte in exchange.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1099511628211
            }
            hash = (hash ^ 0x1F) &* 1099511628211 // record separator
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }

    /// Backfills the index for conversations updated since they were last
    /// indexed — run once on launch when the feature is on.
    func syncAll(_ conversations: [Conversation]) async {
        guard Self.isEnabled else { return }
        for conversation in conversations where !conversation.messages.isEmpty {
            await indexConversation(conversation)
        }
    }

    /// Drops everything remembered from one conversation (called on delete).
    func forget(conversationID: UUID) {
        let before = entries.count
        entries.removeAll { $0.conversationID == conversationID }
        indexedExchangeCounts[conversationID] = nil
        contentSignatures[conversationID] = nil
        if entries.count != before { save() }
    }

    /// Wipes the whole memory index.
    func forgetEverything() {
        entries.removeAll()
        indexedExchangeCounts.removeAll()
        contentSignatures.removeAll()
        save()
    }

    // MARK: - Recall

    /// The most similar past exchanges from *other* conversations.
    func recall(_ query: String, excluding conversationID: UUID, topK: Int = 3, threshold: Double = 0.25) async -> [ChatMemoryHit] {
        guard Self.isEnabled, !entries.isEmpty,
              await provider.probe(),
              let queryVector = await provider.embed(query) else { return [] }
        return entries
            .filter { $0.conversationID != conversationID }
            .map { (entry: $0, score: EmbeddingService.cosineSimilarity(queryVector, $0.embedding)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { ChatMemoryHit(title: $0.entry.title, text: $0.entry.text, date: $0.entry.updatedAt) }
    }

    // MARK: - Chunking

    /// One memory unit per user↔assistant exchange, truncated so a recall
    /// snippet stays compact in the prompt.
    nonisolated static func exchanges(from messages: [ChatMessage]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < messages.count {
            if messages[index].role == .user {
                var text = "User: \(messages[index].content.prefix(300))"
                if index + 1 < messages.count, messages[index + 1].role == .assistant {
                    text += "\nAssistant: \(messages[index + 1].content.prefix(400))"
                    index += 1
                }
                result.append(text)
            }
            index += 1
        }
        return result
    }

    /// Updates cached titles for a conversation's entries. Returns whether any
    /// entry actually changed, so callers can decide whether to persist.
    @discardableResult
    private func refreshTitle(_ conversation: Conversation) -> Bool {
        var changed = false
        for i in entries.indices where entries[i].conversationID == conversation.id && entries[i].title != conversation.title {
            entries[i].title = conversation.title
            changed = true
        }
        return changed
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder().decode(ChatMemoryArchive.self, from: data) else { return }
        entries = archive.entries
        indexedExchangeCounts = archive.indexedExchangeCounts
        contentSignatures = archive.contentSignatures ?? [:]
    }

    private func save() {
        let archive = ChatMemoryArchive(
            entries: entries,
            indexedExchangeCounts: indexedExchangeCounts,
            contentSignatures: contentSignatures
        )
        if let data = try? JSONEncoder().encode(archive) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
