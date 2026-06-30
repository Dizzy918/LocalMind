//
//  KnowledgeBaseStore.swift
//  LocalMind
//
//  Local, on-device document store for retrieval-augmented chat. Documents are
//  chunked and embedded with EmbeddingService; queries retrieve the nearest
//  chunks by cosine similarity. Everything stays in
//  ~/Library/Application Support/LocalMind/knowledge.json — nothing leaves the
//  machine, in keeping with LocalMind's privacy promise.
//

import Foundation

struct KnowledgeChunk: Codable, Identifiable, Sendable {
    let id: UUID
    let documentID: UUID
    let text: String
    let embedding: [Double]
}

struct KnowledgeDocument: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let addedAt: Date
    var chunkCount: Int
}

/// A retrieval result paired with its source document name (for citations).
struct KnowledgeHit: Sendable {
    let documentName: String
    let text: String
    let score: Double
}

private struct KnowledgeArchive: Codable {
    var documents: [KnowledgeDocument]
    var chunks: [KnowledgeChunk]
    var embedderID: String?
}

@Observable
@MainActor
final class KnowledgeBaseStore {
    static let shared = KnowledgeBaseStore()

    private(set) var documents: [KnowledgeDocument] = []
    /// True while a document is being chunked + embedded.
    private(set) var isIndexing = false
    /// The embedding provider this store was built with. Locked once the store
    /// has documents, since vectors from different models aren't comparable.
    private(set) var embedderID: String = "apple"

    private var chunks: [KnowledgeChunk] = []
    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("knowledge.json")
        load()
    }

    var isEmpty: Bool { documents.isEmpty }
    var totalChunks: Int { chunks.count }
    var isAvailable: Bool { EmbeddingService.isAvailable }

    /// Friendly name of the locked embedder, for the documents panel.
    var embedderLabel: String {
        embedderID.hasPrefix("ollama:") ? "Ollama (\(embedderID.dropFirst("ollama:".count)))" : "On-device (Apple)"
    }

    private func provider(forID id: String) -> EmbeddingProvider {
        if id.hasPrefix("ollama:") {
            return OllamaEmbeddingProvider(model: String(id.dropFirst("ollama:".count)))
        }
        return AppleEmbeddingProvider()
    }

    /// Which provider to embed with next: locked to the store's embedder once
    /// it has documents, otherwise the user's preference (falling back to Apple
    /// when Ollama isn't reachable). nil when none is usable right now.
    private func resolveProvider() async -> EmbeddingProvider? {
        if !documents.isEmpty {
            let locked = provider(forID: embedderID)
            return await locked.probe() ? locked : nil
        }
        if (UserDefaults.standard.string(forKey: "embeddingProvider") ?? "apple") == "ollama" {
            let ollama = OllamaEmbeddingProvider()
            if await ollama.probe() { return ollama }
        }
        let apple = AppleEmbeddingProvider()
        return await apple.probe() ? apple : nil
    }

    /// Chunks + embeds off the main actor, then commits the result. Returns the
    /// number of chunks indexed (0 if the text yielded no usable vectors).
    @discardableResult
    func addDocument(name: String, text: String) async -> Int {
        isIndexing = true
        defer { isIndexing = false }

        guard let provider = await resolveProvider() else { return 0 }

        let documentID = UUID()
        var produced: [KnowledgeChunk] = []
        for piece in EmbeddingService.chunk(text) {
            guard let embedding = await provider.embed(piece) else { continue }
            produced.append(KnowledgeChunk(id: UUID(), documentID: documentID, text: piece, embedding: embedding))
        }
        guard !produced.isEmpty else { return 0 }

        // Lock the store to this embedder on the first successful document.
        if documents.isEmpty { embedderID = provider.id }
        documents.append(KnowledgeDocument(id: documentID, name: name, addedAt: Date(), chunkCount: produced.count))
        chunks.append(contentsOf: produced)
        save()
        return produced.count
    }

    func removeDocument(_ document: KnowledgeDocument) {
        chunks.removeAll { $0.documentID == document.id }
        documents.removeAll { $0.id == document.id }
        save()
    }

    func clear() {
        chunks.removeAll()
        documents.removeAll()
        embedderID = "apple"   // free the lock so the store can adopt a new embedder
        save()
    }

    /// Top-`topK` chunks most similar to `query`, each paired with its source
    /// document for citations. Embeds the query with the store's locked
    /// provider so the vectors are comparable. Empty when nothing is relevant.
    func retrieve(_ query: String, topK: Int = 4, threshold: Double = 0.15) async -> [KnowledgeHit] {
        guard !chunks.isEmpty,
              let provider = await resolveProvider(),
              let queryVector = await provider.embed(query) else { return [] }
        let names = Dictionary(documents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return chunks
            .map { (chunk: $0, score: EmbeddingService.cosineSimilarity(queryVector, $0.embedding)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { KnowledgeHit(documentName: names[$0.chunk.documentID] ?? "Document", text: $0.chunk.text, score: $0.score) }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder().decode(KnowledgeArchive.self, from: data) else { return }
        documents = archive.documents
        chunks = archive.chunks
        embedderID = archive.embedderID ?? "apple"
    }

    private func save() {
        let archive = KnowledgeArchive(documents: documents, chunks: chunks, embedderID: embedderID)
        if let data = try? JSONEncoder().encode(archive) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
