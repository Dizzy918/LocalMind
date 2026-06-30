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

private struct KnowledgeArchive: Codable {
    var documents: [KnowledgeDocument]
    var chunks: [KnowledgeChunk]
}

@Observable
@MainActor
final class KnowledgeBaseStore {
    static let shared = KnowledgeBaseStore()

    private(set) var documents: [KnowledgeDocument] = []
    /// True while a document is being chunked + embedded.
    private(set) var isIndexing = false

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

    /// Chunks + embeds off the main actor, then commits the result. Returns the
    /// number of chunks indexed (0 if the text yielded no usable vectors).
    @discardableResult
    func addDocument(name: String, text: String) async -> Int {
        isIndexing = true
        defer { isIndexing = false }

        let built: (doc: KnowledgeDocument, chunks: [KnowledgeChunk])? = await Task.detached(priority: .userInitiated) {
            let documentID = UUID()
            var produced: [KnowledgeChunk] = []
            for piece in EmbeddingService.chunk(text) {
                guard let embedding = EmbeddingService.embed(piece) else { continue }
                produced.append(KnowledgeChunk(id: UUID(), documentID: documentID, text: piece, embedding: embedding))
            }
            guard !produced.isEmpty else { return nil }
            let doc = KnowledgeDocument(id: documentID, name: name, addedAt: Date(), chunkCount: produced.count)
            return (doc, produced)
        }.value

        guard let built else { return 0 }
        documents.append(built.doc)
        chunks.append(contentsOf: built.chunks)
        save()
        return built.chunks.count
    }

    func removeDocument(_ document: KnowledgeDocument) {
        chunks.removeAll { $0.documentID == document.id }
        documents.removeAll { $0.id == document.id }
        save()
    }

    func clear() {
        chunks.removeAll()
        documents.removeAll()
        save()
    }

    /// Returns the top-`topK` chunks most similar to `query`, each scoring at
    /// least `threshold`. Empty when nothing is relevant enough.
    func search(_ query: String, topK: Int = 4, threshold: Double = 0.15) -> [KnowledgeChunk] {
        guard !chunks.isEmpty, let queryVector = EmbeddingService.embed(query) else { return [] }
        return chunks
            .map { (chunk: $0, score: EmbeddingService.cosineSimilarity(queryVector, $0.embedding)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0.chunk }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder().decode(KnowledgeArchive.self, from: data) else { return }
        documents = archive.documents
        chunks = archive.chunks
    }

    private func save() {
        let archive = KnowledgeArchive(documents: documents, chunks: chunks)
        if let data = try? JSONEncoder().encode(archive) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
