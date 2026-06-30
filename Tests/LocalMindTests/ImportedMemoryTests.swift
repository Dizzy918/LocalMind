//
//  ImportedMemoryTests.swift
//  LocalMindTests
//
//  Verifies the cross-AI memory import parser tolerates the messy
//  shapes other AIs return: markdown fences, leading prose, etc.
//

import XCTest
@testable import LocalMind

final class ImportedMemoryTests: XCTestCase {

    func testParsesCleanJSON() throws {
        let json = """
        {
          "name": "Rado",
          "role": "iOS engineer",
          "facts": ["lives in Sofia"],
          "preferences": ["concise replies"],
          "communication_style": "direct",
          "ongoing_projects": ["LocalMind"],
          "do_not": ["use emojis"]
        }
        """
        let memory = try ImportedMemory.parse(json)
        XCTAssertEqual(memory.name, "Rado")
        XCTAssertEqual(memory.role, "iOS engineer")
        XCTAssertEqual(memory.facts, ["lives in Sofia"])
        XCTAssertEqual(memory.preferences, ["concise replies"])
        XCTAssertEqual(memory.do_not, ["use emojis"])
    }

    func testStripsMarkdownFences() throws {
        let raw = """
        Here is the summary you asked for:

        ```json
        {
          "name": "Alice",
          "role": "PM",
          "facts": [],
          "preferences": [],
          "communication_style": "",
          "ongoing_projects": [],
          "do_not": []
        }
        ```

        Hope that helps!
        """
        let memory = try ImportedMemory.parse(raw)
        XCTAssertEqual(memory.name, "Alice")
    }

    func testToleratesLeadingProse() throws {
        let raw = """
        Sure! Here's everything I know about you:
        { "name": "Bob", "role": "designer", "facts": ["uses Figma"], "preferences": [], "communication_style": "", "ongoing_projects": [], "do_not": [] }
        """
        let memory = try ImportedMemory.parse(raw)
        XCTAssertEqual(memory.name, "Bob")
        XCTAssertEqual(memory.facts, ["uses Figma"])
    }

    func testThrowsWhenNoJSONFound() {
        XCTAssertThrowsError(try ImportedMemory.parse("I don't know anything about you yet."))
    }

    func testRenderForPersonalContextOmitsEmptyFields() {
        let memory = ImportedMemory(name: "Rado", role: "", facts: ["a", "b"])
        let rendered = memory.renderForPersonalContext()
        XCTAssertTrue(rendered.contains("Name: Rado"))
        XCTAssertFalse(rendered.contains("Role:"))   // empty role suppressed
        XCTAssertTrue(rendered.contains("- a"))
        XCTAssertTrue(rendered.contains("- b"))
        XCTAssertFalse(rendered.contains("## Preferences"))  // empty array suppressed
    }
}
