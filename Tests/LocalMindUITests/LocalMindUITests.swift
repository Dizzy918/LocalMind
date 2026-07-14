//
//  LocalMindUITests.swift
//  LocalMindUITests
//
//  UI smoke tests: launch the real app and click through the primary
//  chrome. These deliberately avoid sending messages (no backend in CI) —
//  they exist to catch broken launch paths, missing views, and dead
//  buttons, the class of bug unit tests can't see.
//

import XCTest

final class LocalMindUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches signed in (creating a guest profile on fresh machines).
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-autosignin"]
        app.launch()
        return app
    }

    @MainActor
    func testLaunchShowsWelcomeScreen() throws {
        let app = launchApp()

        // The centered welcome prompt is the app's resting state.
        XCTAssertTrue(
            app.staticTexts["What can I help you with?"].waitForExistence(timeout: 15),
            "welcome screen should appear after launch"
        )
        // Sidebar chrome.
        XCTAssertTrue(app.staticTexts["LocalMind"].exists)
    }

    @MainActor
    func testAgentTeamPanelOpensAndCloses() throws {
        let app = launchApp()
        guard app.staticTexts["What can I help you with?"].waitForExistence(timeout: 15) else {
            return XCTFail("app did not reach the welcome screen")
        }

        // The welcome layout offers "Ask multiple agents" when agents exist
        // (starter agents are seeded on first launch).
        let teamButton = app.buttons["Ask multiple agents"].firstMatch
        guard teamButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("No agents present on this machine — team entry point hidden")
        }
        teamButton.click()

        XCTAssertTrue(
            app.staticTexts["Agent Team"].waitForExistence(timeout: 5),
            "the Agent Team sheet should open"
        )

        app.buttons["Close"].firstMatch.click()
        XCTAssertTrue(
            app.staticTexts["What can I help you with?"].waitForExistence(timeout: 5),
            "closing the sheet should return to the welcome screen"
        )
    }

    @MainActor
    func testTypingEnablesInput() throws {
        let app = launchApp()
        guard app.staticTexts["What can I help you with?"].waitForExistence(timeout: 15) else {
            return XCTFail("app did not reach the welcome screen")
        }

        let field = app.textFields["Message LocalMind..."].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "message input should exist")
        field.click()
        field.typeText("hello from the UI test")
        // Draft text lands in the field (not asserting send — no backend in CI).
        XCTAssertTrue((field.value as? String)?.contains("hello from the UI test") ?? false)
    }

    @MainActor
    func testSettingsOpensAgentsTab() throws {
        let app = launchApp()
        guard app.staticTexts["What can I help you with?"].waitForExistence(timeout: 15) else {
            return XCTFail("app did not reach the welcome screen")
        }

        app.typeKey(",", modifierFlags: .command)

        // Settings is its own window; the Agents tab is in its toolbar.
        let agentsTab = app.buttons["Agents"].firstMatch
        guard agentsTab.waitForExistence(timeout: 10) else {
            return XCTFail("Settings window (or its Agents tab) did not appear")
        }
        agentsTab.click()
        XCTAssertTrue(
            app.buttons["New Agent"].firstMatch.waitForExistence(timeout: 5),
            "the Agents tab should show the New Agent button"
        )
    }
}
