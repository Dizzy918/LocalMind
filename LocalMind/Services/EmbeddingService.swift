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
    ///
    /// Every vector this returns on a given device shares ONE dimension.
    /// That invariant matters: sentence vectors (~512-dim) and the
    /// word-centroid fallback (~300-dim) are different sizes, and
    /// `cosineSimilarity` returns 0 across a size mismatch — so if a store
    /// mixed the two, any chunk embedded the "other" way became silently
    /// unretrievable. To prevent that we stay in the sentence space whenever
    /// the sentence model exists (averaging over pieces when a whole string
    /// won't embed), and only fall back to word vectors when the device has
    /// no sentence model at all — in which case *everything* is word-space.
    static func embed(_ text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let sentence {
            if let vector = sentence.vector(for: trimmed) {
                return vector
            }
            // Long / awkward input the sentence model rejects wholesale: embed
            // its pieces and average, keeping the sentence dimension. Returning
            // nil (skip) is preferable to emitting a word-space vector that
            // would silently never match the rest of the store.
            return averagedSentenceVector(trimmed, model: sentence)
        }

        // No sentence model on this device — use word vectors, consistently.
        return wordCentroid(trimmed)
    }

    /// Averages the sentence vectors of a long string's pieces (sentences,
    /// then hard-split sub-pieces) so the result stays in the sentence space.
    private static func averagedSentenceVector(_ text: String, model: NLEmbedding) -> [Double]? {
        var pieces = splitIntoSentences(text)
        // A single "sentence" can still be too long; hard-split those further.
        pieces = pieces.flatMap { piece -> [String] in
            model.vector(for: piece) != nil ? [piece] : hardSplit(piece, maxChars: 200)
        }

        var sum: [Double]?
        var count = 0
        for piece in pieces {
            guard let vector = model.vector(for: piece) else { continue }
            if sum == nil { sum = [Double](repeating: 0, count: vector.count) }
            guard sum?.count == vector.count else { continue }
            for i in 0..<vector.count { sum![i] += vector[i] }
            count += 1
        }
        guard var result = sum, count > 0 else { return nil }
        for i in result.indices { result[i] /= Double(count) }
        return result
    }

    /// Centroid of a string's in-vocabulary word vectors (word space).
    private static func wordCentroid(_ text: String) -> [Double]? {
        guard let word else { return nil }
        var sum = [Double](repeating: 0, count: word.dimension)
        var count = 0
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let vector = word.vector(for: String(token)) {
                for i in 0..<sum.count { sum[i] += vector[i] }
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return sum.map { $0 / Double(count) }
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let piece = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
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
