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
}

@Observable
@MainActor
final class ChatMemoryStore {
    static let shared = ChatMemoryStore()

    private(set) var entries: [ChatMemoryEntry] = []
    /// How many exchanges of each conversation are already indexed, so
    /// re-indexing after a new turn only embeds the delta.
    private var indexedExchangeCounts: [UUID: Int] = [:]
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
        let alreadyIndexed = indexedExchangeCounts[conversation.id] ?? 0
        guard exchanges.count > alreadyIndexed else {
            // Still refresh the title — it's AI-generated shortly after the
            // first exchange, and recalled snippets should show the real one.
            refreshTitle(conversation)
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
        refreshTitle(conversation)
        save()
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
        if entries.count != before { save() }
    }

    /// Wipes the whole memory index.
    func forgetEverything() {
        entries.removeAll()
        indexedExchangeCounts.removeAll()
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

    private func refreshTitle(_ conversation: Conversation) {
        for i in entries.indices where entries[i].conversationID == conversation.id && entries[i].title != conversation.title {
            entries[i].title = conversation.title
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder().decode(ChatMemoryArchive.self, from: data) else { return }
        entries = archive.entries
        indexedExchangeCounts = archive.indexedExchangeCounts
    }

    private func save() {
        let archive = ChatMemoryArchive(entries: entries, indexedExchangeCounts: indexedExchangeCounts)
        if let data = try? JSONEncoder().encode(archive) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
