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
        let chunks = EmbeddingService.chunk(String(repeating: "x", count: 1000), maxChars: 300)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 300 })
    }

    // MARK: - Dimension consistency
    //
    // The bug these guard: `embed` used to return ~512-dim sentence vectors for
    // short text and fall back to ~300-dim word-centroid vectors for long or
    // out-of-vocabulary text. cosineSimilarity returns 0 across a size
    // mismatch, so mixed-dimension entries silently never matched. Every vector
    // on a device must now share one dimension.

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
