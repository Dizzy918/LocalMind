//
//  LexicalSearch.swift
//  LocalMind
//
//  Keyword scoring (BM25) and rank fusion for the knowledge base.
//
//  Pure vector search is good at paraphrase and bad at exact tokens: an error
//  code, a filename, a person's name, or an API symbol often has a weak
//  embedding signal but is unmistakable as a literal match. Blending a keyword
//  ranking with the vector ranking recovers those cases without giving up
//  semantic matching — the standard hybrid-retrieval trade.
//
//  Everything here is pure and synchronous so retrieval behaviour is testable
//  without embeddings, which aren't guaranteed to exist on a given machine.
//

import Foundation

/// BM25 over a fixed corpus of chunks, built once and reused across queries.
nonisolated struct LexicalIndex: Sendable {
    /// Per-chunk term frequencies and length, in corpus order.
    private struct Entry: Sendable {
        let id: UUID
        let termFrequencies: [String: Int]
        let length: Int
    }

    private let entries: [Entry]
    /// term -> how many chunks contain it, for IDF.
    private let documentFrequencies: [String: Int]
    private let averageLength: Double

    /// Standard BM25 constants: `k1` controls term-frequency saturation, `b`
    /// how much long chunks are penalised.
    private static let k1 = 1.2
    private static let b = 0.75

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    init(documents: [(id: UUID, text: String)]) {
        var entries: [Entry] = []
        var documentFrequencies: [String: Int] = [:]
        var totalLength = 0

        for document in documents {
            let tokens = Self.tokenize(document.text)
            var frequencies: [String: Int] = [:]
            for token in tokens { frequencies[token, default: 0] += 1 }
            for term in frequencies.keys { documentFrequencies[term, default: 0] += 1 }
            totalLength += tokens.count
            entries.append(Entry(id: document.id, termFrequencies: frequencies, length: tokens.count))
        }

        self.entries = entries
        self.documentFrequencies = documentFrequencies
        self.averageLength = entries.isEmpty ? 0 : Double(totalLength) / Double(entries.count)
    }

    /// Lowercased alphanumeric tokens. Deliberately simple: no stemming, so an
    /// exact identifier stays exactly itself, which is the point of having a
    /// lexical leg at all.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
    }

    /// BM25 score per chunk for `query`, keyed by chunk id. Chunks that match
    /// nothing are omitted rather than scored zero.
    func scores(for query: String) -> [UUID: Double] {
        guard !entries.isEmpty, averageLength > 0 else { return [:] }
        let terms = Set(Self.tokenize(query))
        guard !terms.isEmpty else { return [:] }

        let totalDocuments = Double(entries.count)
        var results: [UUID: Double] = [:]

        for entry in entries {
            var score = 0.0
            for term in terms {
                guard let frequency = entry.termFrequencies[term] else { continue }
                let containing = Double(documentFrequencies[term] ?? 0)
                // Smoothed IDF; clamped at zero so a term in every chunk
                // contributes nothing instead of going negative.
                let idf = max(0, log((totalDocuments - containing + 0.5) / (containing + 0.5) + 1))
                let tf = Double(frequency)
                let norm = tf + Self.k1 * (1 - Self.b + Self.b * Double(entry.length) / averageLength)
                score += idf * (tf * (Self.k1 + 1)) / norm
            }
            if score > 0 { results[entry.id] = score }
        }
        return results
    }
}

/// Reciprocal-rank fusion of several rankings.
///
/// Fusing on *rank* rather than score is deliberate: cosine similarity lives in
/// [-1, 1] while BM25 is unbounded and corpus-dependent, so any attempt to
/// average them directly needs normalisation constants that quietly go wrong on
/// a different corpus. RRF only asks each ranking what it put first.
nonisolated enum RankFusion {
    /// Standard RRF damping constant — large enough that the top few ranks
    /// don't overwhelm agreement further down.
    static let defaultK = 60.0

    /// Fused score per id: the sum of `1 / (k + rank)` across every ranking
    /// the id appears in, so items both rankings like beat items only one does.
    static func reciprocalRank(_ rankings: [[UUID]], k: Double = defaultK) -> [UUID: Double] {
        var fused: [UUID: Double] = [:]
        for ranking in rankings {
            for (index, id) in ranking.enumerated() {
                fused[id, default: 0] += 1 / (k + Double(index + 1))
            }
        }
        return fused
    }
}
