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
}
