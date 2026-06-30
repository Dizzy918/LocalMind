//
//  EmbeddingService.swift
//  LocalMind
//
//  On-device text embeddings via Apple's NaturalLanguage framework — zero
//  setup, fully local, and independent of which chat backend is active. Used
//  to power "chat with your documents" (local retrieval-augmented generation).
//

import Foundation
import NaturalLanguage

enum EmbeddingService {
    // Sentence embedding captures more semantics but returns nil for long or
    // out-of-vocabulary text; we fall back to averaging word vectors so a
    // chunk always produces *some* vector.
    private static let sentence = NLEmbedding.sentenceEmbedding(for: .english)
    private static let word = NLEmbedding.wordEmbedding(for: .english)

    /// Whether on-device embeddings are usable on this machine.
    static var isAvailable: Bool { sentence != nil || word != nil }

    /// Embeds a piece of text into a vector, or nil if no signal could be
    /// extracted (empty / entirely out-of-vocabulary).
    static func embed(_ text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let sentence, let vector = sentence.vector(for: trimmed) {
            return vector
        }

        // Fallback: centroid of in-vocabulary word vectors.
        guard let word else { return nil }
        var sum = [Double](repeating: 0, count: word.dimension)
        var count = 0
        for token in trimmed.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let vector = word.vector(for: String(token)) {
                for i in 0..<sum.count { sum[i] += vector[i] }
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return sum.map { $0 / Double(count) }
    }

    /// Cosine similarity in [-1, 1]; 0 when either vector is degenerate.
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }

    /// Splits text into retrieval-sized chunks, preferring paragraph
    /// boundaries and hard-splitting any paragraph longer than `maxChars`.
    static func chunk(_ text: String, maxChars: Int = 700) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
        }

        for paragraph in paragraphs {
            if paragraph.count > maxChars {
                flush()
                chunks.append(contentsOf: hardSplit(paragraph, maxChars: maxChars))
            } else if current.isEmpty {
                current = paragraph
            } else if current.count + paragraph.count + 2 <= maxChars {
                current += "\n\n" + paragraph
            } else {
                flush()
                current = paragraph
            }
        }
        flush()
        return chunks
    }

    private static func hardSplit(_ text: String, maxChars: Int) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}
