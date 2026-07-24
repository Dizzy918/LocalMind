//
//  EmbeddingTests.swift
//  LocalMindTests
//
//  Covers the deterministic, model-independent parts of EmbeddingService —
//  cosine similarity and the document chunker — so retrieval math stays
//  correct regardless of whether NLEmbedding models are present in CI.
//

import XCTest
@testable import LocalMind

final class EmbeddingTests: XCTestCase {

    // MARK: - Cosine similarity

    func testCosineOfIdenticalVectorsIsOne() {
        let v = [1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(EmbeddingService.cosineSimilarity(v, v), 1.0, accuracy: 1e-9)
    }

    func testCosineOfOrthogonalVectorsIsZero() {
        XCTAssertEqual(EmbeddingService.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 1e-9)
    }

    func testCosineOfOppositeVectorsIsMinusOne() {
        XCTAssertEqual(EmbeddingService.cosineSimilarity([1, 0], [-1, 0]), -1.0, accuracy: 1e-9)
    }

    func testCosineWithMismatchedLengthsIsZero() {
        XCTAssertEqual(EmbeddingService.cosineSimilarity([1, 2, 3], [1, 2]), 0.0)
    }

    func testCosineWithZeroVectorIsZero() {
        XCTAssertEqual(EmbeddingService.cosineSimilarity([0, 0], [1, 1]), 0.0)
    }

    // MARK: - Chunking

    func testShortTextProducesSingleChunk() {
        XCTAssertEqual(EmbeddingService.chunk("Hello world.", maxChars: 700), ["Hello world."])
    }

    func testParagraphsPackIntoOneChunkWhenTheyFit() {
        let chunks = EmbeddingService.chunk("Para one.\n\nPara two.\n\nPara three.", maxChars: 700)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("Para one."))
        XCTAssertTrue(chunks[0].contains("Para three."))
    }

    func testParagraphsSplitWhenExceedingMax() {
        let a = String(repeating: "a", count: 50)
        let b = String(repeating: "b", count: 50)
        XCTAssertEqual(EmbeddingService.chunk("\(a)\n\n\(b)", maxChars: 60).count, 2)
    }

    func testLongParagraphIsHardSplit() {
        // maxChars caps *new* content per chunk; carried-over overlap is added
        // on top, so the cap for the whole chunk is maxChars + overlapChars.
        let chunks = EmbeddingService.chunk(String(repeating: "x", count: 1000), maxChars: 300, overlapChars: 0)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 300 })
    }

    // MARK: - Chunk overlap
    //
    // Without overlap, a fact that straddles a chunk boundary is cut so neither
    // half states it fully — the document plainly contains the answer and
    // retrieval still can't surface it.

    func testConsecutiveChunksCarryPrecedingContext() {
        let first = String(repeating: "alpha ", count: 40).trimmingCharacters(in: .whitespaces)
        let second = String(repeating: "beta ", count: 40).trimmingCharacters(in: .whitespaces)
        let chunks = EmbeddingService.chunk("\(first)\n\n\(second)", maxChars: 250, overlapChars: 60)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks[1].contains("alpha"), "the second chunk should carry the tail of the first")
        XCTAssertTrue(chunks[1].contains("beta"), "…without losing its own content")
    }

    func testOverlapDoesNotStartMidWord() {
        let a = String(repeating: "windmill ", count: 30).trimmingCharacters(in: .whitespaces)
        let b = String(repeating: "seashore ", count: 30).trimmingCharacters(in: .whitespaces)
        let chunks = EmbeddingService.chunk("\(a)\n\n\(b)", maxChars: 250, overlapChars: 55)

        XCTAssertGreaterThan(chunks.count, 1)
        // The carried context begins at a word boundary, so no partial token.
        let carried = chunks[1].prefix(while: { $0 != "\n" })
        XCTAssertFalse(carried.hasPrefix("indmill"))
        XCTAssertFalse(carried.hasPrefix("dmill"))
    }

    func testSingleChunkIsUnaffectedByOverlap() {
        XCTAssertEqual(EmbeddingService.chunk("Just one short line.", maxChars: 700), ["Just one short line."])
    }

    // MARK: - Dimension consistency
    //
    // The bug these guard: `embed` used to return ~512-dim sentence vectors for
    // short text and fall back to ~300-dim word-centroid vectors for long or
    // out-of-vocabulary text. cosineSimilarity returns 0 across a size
    // mismatch, so mixed-dimension entries silently never matched. Every vector
    // on a device must now share one dimension.

    // MARK: - Stitching chunks back into source text
    //
    // Rebuilding a document whose original file has moved has to reconstruct
    // the text from what's indexed. Overlap makes that non-trivial: naively
    // rejoining would fold the carried context into the text a little more on
    // every rebuild.

    func testStitchDropsCarriedOverlap() {
        let first = "The release ships on Friday."
        // How applyOverlap builds a chunk: carried tail, blank line, own text.
        let second = "ships on Friday.\n\nMigrations run first."
        let stitched = KnowledgeBaseStore.stitch([first, second])

        XCTAssertEqual(stitched, "The release ships on Friday.\n\nMigrations run first.")
        XCTAssertEqual(stitched.components(separatedBy: "ships on Friday.").count - 1, 1,
                       "the carried sentence must appear once, not twice")
    }

    func testStitchLeavesNonOverlappedChunksAlone() {
        // Documents indexed before overlap existed must rejoin unchanged.
        let stitched = KnowledgeBaseStore.stitch(["Alpha content.", "Beta content."])
        XCTAssertEqual(stitched, "Alpha content.\n\nBeta content.")
    }

    func testStitchIsStableAcrossRepeatedRebuilds() {
        // Chunk → stitch → chunk → stitch must converge, or each rebuild would
        // grow the document.
        let source = (1...12).map { "Paragraph number \($0) with enough words to matter." }
            .joined(separator: "\n\n")
        let once = KnowledgeBaseStore.stitch(EmbeddingService.chunk(source, maxChars: 120, overlapChars: 40))
        let twice = KnowledgeBaseStore.stitch(EmbeddingService.chunk(once, maxChars: 120, overlapChars: 40))
        XCTAssertEqual(once, twice)
    }

    func testStitchHandlesEdgeCases() {
        XCTAssertEqual(KnowledgeBaseStore.stitch([]), "")
        XCTAssertEqual(KnowledgeBaseStore.stitch(["only"]), "only")
    }

    // MARK: - Lexical (BM25) search

    private func lexicalCorpus() -> (index: LexicalIndex, ids: [UUID]) {
        let ids = (0..<4).map { _ in UUID() }
        let index = LexicalIndex(documents: [
            (ids[0], "The deployment failed with error code E4021 during startup."),
            (ids[1], "Cooking pasta requires salted boiling water and good olive oil."),
            (ids[2], "Our release process runs migrations before restarting services."),
            (ids[3], "Error handling in Swift uses do, try, catch, and throws."),
        ])
        return (index, ids)
    }

    func testExactTokenRanksFirst() {
        // The case hybrid search exists for: an error code has a weak embedding
        // signal but an unmistakable literal match.
        let (index, ids) = lexicalCorpus()
        let scores = index.scores(for: "E4021")
        XCTAssertEqual(scores.count, 1)
        XCTAssertNotNil(scores[ids[0]])
    }

    func testRareTermsOutrankCommonOnes() {
        let (index, ids) = lexicalCorpus()
        let scores = index.scores(for: "migrations error")
        // "migrations" appears once, "error" twice — the rarer term should
        // pull its chunk above a chunk matching only the common one.
        XCTAssertGreaterThan(scores[ids[2]] ?? 0, scores[ids[3]] ?? 0)
    }

    func testUnmatchedQueryScoresNothing() {
        let (index, _) = lexicalCorpus()
        XCTAssertTrue(index.scores(for: "helicopter").isEmpty)
        XCTAssertTrue(index.scores(for: "").isEmpty)
    }

    func testEmptyIndexIsSafe() {
        let index = LexicalIndex(documents: [])
        XCTAssertTrue(index.isEmpty)
        XCTAssertTrue(index.scores(for: "anything").isEmpty)
    }

    // MARK: - Rank fusion

    func testAgreementBeatsASingleStrongRanking() {
        let agreed = UUID(), vectorOnly = UUID(), lexicalOnly = UUID()
        // `agreed` is second in both lists; the others are first in one list
        // and absent from the other.
        let fused = RankFusion.reciprocalRank([
            [vectorOnly, agreed],
            [lexicalOnly, agreed],
        ])
        XCTAssertGreaterThan(fused[agreed] ?? 0, fused[vectorOnly] ?? 0)
        XCTAssertGreaterThan(fused[agreed] ?? 0, fused[lexicalOnly] ?? 0)
    }

    func testFusionFallsBackToASingleRanking() {
        // Embeddings unavailable: the keyword leg alone must still rank.
        let a = UUID(), b = UUID()
        let fused = RankFusion.reciprocalRank([[], [a, b]])
        XCTAssertGreaterThan(fused[a] ?? 0, fused[b] ?? 0)
    }

    func testFusionOfNothingIsEmpty() {
        XCTAssertTrue(RankFusion.reciprocalRank([[], []]).isEmpty)
    }

    func testEmbeddingsShareOneDimensionAcrossShortAndLongText() throws {
        try XCTSkipUnless(EmbeddingService.isAvailable, "NLEmbedding models not present on this machine")

        let short = EmbeddingService.embed("Hello there, friend.")
        // Long enough that the whole-string sentence embedding may bail and
        // take the averaging path — which must stay in the same space.
        let long = EmbeddingService.embed(
            String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 80)
        )

        let shortDim = try XCTUnwrap(short, "short text should embed")
        let longDim = try XCTUnwrap(long, "long text should embed")
        XCTAssertEqual(shortDim.count, longDim.count,
                       "all vectors must share one dimension or cosine similarity silently drops matches")
        // And they must actually be comparable (non-zero self-similarity path).
        XCTAssertEqual(EmbeddingService.cosineSimilarity(shortDim, shortDim), 1.0, accuracy: 1e-6)
    }
}
