//
//  RequestEncodingTests.swift
//  LocalMindTests
//
//  Guards the wire format of chat requests.
//
//  These exist because tool calling was broken end to end by a serialization
//  bug that every other test missed: the mock backend used throughout the
//  suite never encodes anything, so a body that JSONSerialization refuses to
//  write looked fine everywhere except against a real server. The tool schema
//  is an AnyCodable — a Swift struct — and passing one to JSONSerialization
//  raises an Objective-C exception that `try` cannot catch, so the failure
//  wasn't even a caught error; it terminated the process.
//
//  Anything that ends up in a request body gets checked here.
//

import XCTest
@testable import LocalMind

final class RequestEncodingTests: XCTestCase {

    /// The shape an MCP server actually advertises, as it arrives after
    /// decoding — nested objects, arrays, mixed value types.
    private func realisticToolSchema() throws -> AnyCodable {
        let json = """
        {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "File to read" },
            "head": { "type": "number" },
            "recursive": { "type": "boolean" },
            "excludePatterns": { "type": "array", "items": { "type": "string" } }
          },
          "required": ["path"]
        }
        """
        return try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    private func tool(schema: AnyCodable) -> AITool {
        AITool(id: "read_file", name: "read_file", description: "Read a file", inputSchema: schema)
    }

    // MARK: - The bug

    func testRawAnyCodableIsNotSerializable() throws {
        // Documents the trap: the wrapper itself can never go into a body.
        // isValidJSONObject is the only safe way to ask — actually calling
        // data(withJSONObject:) on this raises an uncatchable exception.
        let schema = try realisticToolSchema()
        let body: [String: Any] = ["tools": [["function": ["parameters": schema]]]]
        XCTAssertFalse(JSONSerialization.isValidJSONObject(body),
                       "if this ever passes, the wrapper changed and the unwrap may be unnecessary")
    }

    func testUnwrappedSchemaIsSerializable() throws {
        let schema = try realisticToolSchema()
        let body: [String: Any] = ["tools": [["function": ["parameters": schema.jsonValue]]]]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testUnwrapPreservesTheWholeSchema() throws {
        let schema = try realisticToolSchema()
        let data = try JSONSerialization.data(withJSONObject: schema.jsonValue)
        let roundTripped = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(roundTripped["type"] as? String, "object")
        XCTAssertEqual(roundTripped["required"] as? [String], ["path"])

        let properties = try XCTUnwrap(roundTripped["properties"] as? [String: Any])
        XCTAssertEqual(properties.count, 4, "no property may be dropped — the model needs the full schema")

        // Nested objects and arrays survive, not just top-level scalars.
        let path = try XCTUnwrap(properties["path"] as? [String: Any])
        XCTAssertEqual(path["description"] as? String, "File to read")
        let exclude = try XCTUnwrap(properties["excludePatterns"] as? [String: Any])
        XCTAssertEqual((exclude["items"] as? [String: Any])?["type"] as? String, "string")
    }

    func testNestedWrappersAreUnwrappedToo() {
        // A schema built in code rather than decoded can nest wrappers.
        let nested = AnyCodable([
            "outer": AnyCodable(["inner": AnyCodable("value")])
        ] as [String: Any])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["k": nested.jsonValue]))
    }

    // MARK: - Guarded encoder

    func testEncoderProducesToolsWhenTheyAreValid() throws {
        let schema = try realisticToolSchema()
        let body: [String: Any] = [
            "model": "qwen3:8b",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [["type": "function",
                       "function": ["name": "read_file", "parameters": schema.jsonValue]]]
        ]
        let data = try encodeChatRequestBody(body)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(decoded["tools"], "valid tools must actually reach the server")
    }

    func testEncoderDropsToolsRatherThanCrashing() throws {
        // A server advertising something unrepresentable must cost us tools for
        // one request, not the whole app.
        let body: [String: Any] = [
            "model": "m",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [["function": ["parameters": AnyCodable(["a": 1])]]],
            "tool_choice": "auto"
        ]
        let data = try encodeChatRequestBody(body)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(decoded["tools"])
        XCTAssertNil(decoded["tool_choice"])
        XCTAssertEqual(decoded["model"] as? String, "m", "the request still goes out, just without tools")
    }

    func testEncoderThrowsWhenEvenTheBaseBodyIsInvalid() {
        // Nothing to salvage: a Swift error is fine here, it's catchable.
        let body: [String: Any] = ["messages": AnyCodable(["x": 1])]
        XCTAssertThrowsError(try encodeChatRequestBody(body))
    }

    // MARK: - Full request bodies, as the services build them

    /// Mirrors OllamaService's body construction closely enough to catch a
    /// regression in the parts that matter for the wire format.
    func testOllamaStyleBodyWithToolsEncodes() throws {
        let schema = try realisticToolSchema()
        let tools = [tool(schema: schema)]
        let body: [String: Any] = [
            "model": "qwen3:8b",
            "messages": [["role": "user", "content": "what files are in Downloads?"]],
            "stream": true,
            "keep_alive": "1h",
            "tools": tools.map { t -> [String: Any] in
                ["type": "function",
                 "function": ["name": t.name, "description": t.description, "parameters": t.inputSchema.jsonValue]]
            },
            "options": ["temperature": 0.7, "num_ctx": 4096]
        ]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertNoThrow(try encodeChatRequestBody(body))
    }

    /// Same for the OpenAI-compatible shape, including a tool-result turn.
    func testOpenAIStyleBodyWithToolMessagesEncodes() throws {
        let schema = try realisticToolSchema()
        let body: [String: Any] = [
            "model": "local-model",
            "messages": [
                ["role": "user", "content": "what files are in Downloads?"],
                ["role": "assistant", "content": "",
                 "tool_calls": [["id": "call_1", "type": "function",
                                 "function": ["name": "list_directory", "arguments": "{\"path\":\"~/Downloads\"}"]]]],
                ["role": "tool", "content": "a.txt\nb.pdf", "tool_call_id": "call_1"]
            ],
            "stream": true,
            "tools": [["type": "function",
                       "function": ["name": "list_directory", "description": "", "parameters": schema.jsonValue]]],
            "tool_choice": "auto"
        ]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertNoThrow(try encodeChatRequestBody(body))
    }
}
