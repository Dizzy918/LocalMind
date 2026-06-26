//
//  AIServiceErrorTests.swift
//  LocalMindTests
//
//  Tests for AIServiceError error descriptions and recovery suggestions.
//

import XCTest
@testable import LocalMind

final class AIServiceErrorTests: XCTestCase {

    func testAllErrorsHaveDescriptions() {
        let errors: [AIServiceError] = [
            .backendUnavailable("Test"),
            .serverError("Test"),
            .modelNotFound("Test"),
            .generationFailed("Test"),
            .networkError("Test"),
            .timeout,
            .noBackendAvailable
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                            "Every AIServiceError case should have an errorDescription")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true,
                           "errorDescription should not be empty for \(error)")
        }
    }

    func testAllErrorsHaveRecoverySuggestions() {
        let errors: [AIServiceError] = [
            .backendUnavailable("Test"),
            .serverError("Test"),
            .modelNotFound("Test"),
            .generationFailed("Test"),
            .networkError("Test"),
            .timeout,
            .noBackendAvailable
        ]

        for error in errors {
            XCTAssertNotNil(error.recoverySuggestion,
                            "Every AIServiceError case should have a recoverySuggestion")
            XCTAssertFalse(error.recoverySuggestion?.isEmpty ?? true,
                           "recoverySuggestion should not be empty for \(error)")
        }
    }

    func testErrorDescriptionsAreUserFacing() {
        // Errors should not include technical jargon like stack traces or raw NSError codes
        let serverError = AIServiceError.serverError("Connection refused")
        XCTAssertTrue(serverError.errorDescription?.contains("Server Error") ?? false)
        XCTAssertTrue(serverError.errorDescription?.contains("Connection refused") ?? false)
    }

    func testRecoverySuggestionsActionable() {
        XCTAssertTrue(
            AIServiceError.noBackendAvailable.recoverySuggestion?.contains("Ollama") ?? false,
            "noBackendAvailable should suggest installing Ollama"
        )

        XCTAssertTrue(
            AIServiceError.timeout.recoverySuggestion?.lowercased().contains("wait") ?? false,
            "timeout should suggest waiting"
        )
    }
}
