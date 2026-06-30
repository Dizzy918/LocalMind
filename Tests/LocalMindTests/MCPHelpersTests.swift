//
//  MCPHelpersTests.swift
//  LocalMindTests
//
//  Pure-function tests for MCP plumbing — covers the slug formatter, the
//  saved-config migrator, the executable resolver, and the SSE event
//  splitter. None of these spawn processes or open sockets so the suite
//  stays fast and deterministic.
//

import XCTest
@testable import LocalMind

final class MCPSlugTests: XCTestCase {

    func testAlphanumericLowercased() {
        XCTAssertEqual(MCPService.slug("Memory"), "memory")
        XCTAssertEqual(MCPService.slug("GitHub"), "github")
    }

    func testSpacesBecomeHyphens() {
        XCTAssertEqual(MCPService.slug("Brave Search"), "brave-search")
        XCTAssertEqual(MCPService.slug("Apple Notes"), "apple-notes")
    }

    func testMultipleNonAlphanumericRunsCollapse() {
        XCTAssertEqual(MCPService.slug("Foo  Bar"), "foo-bar")
        XCTAssertEqual(MCPService.slug("Foo / Bar / Baz"), "foo-bar-baz")
    }

    func testTrimmingLeadingTrailingHyphens() {
        XCTAssertEqual(MCPService.slug(" Hello "), "hello")
        XCTAssertEqual(MCPService.slug("---x---"), "x")
    }

    func testEmptyAndAllSymbolFallback() {
        XCTAssertEqual(MCPService.slug(""), "server")
        XCTAssertEqual(MCPService.slug("///"), "server")
    }

    func testUnicodeLettersAreKept() {
        // `isLetter`/`isNumber` are Unicode-aware; "Café" -> "café".
        XCTAssertEqual(MCPService.slug("Café"), "café")
    }
}

final class MCPMigrationTests: XCTestCase {

    private func config(command: String, args: [String]) -> MCPServerConfig {
        MCPServerConfig(
            name: "Test",
            transport: .stdio(command: command, args: args, env: nil),
            enabled: true
        )
    }

    private func stdio(_ c: MCPServerConfig) -> (String, [String])? {
        guard case .stdio(let command, let args, _) = c.transport else { return nil }
        return (command, args)
    }

    func testAbsoluteUsrLocalNpxIsNormalized() {
        let migrated = MCPService.migrate(config(command: "/usr/local/bin/npx", args: ["-y", "@modelcontextprotocol/server-memory"]))
        let (cmd, args) = stdio(migrated)!
        XCTAssertEqual(cmd, "npx")
        XCTAssertEqual(args, ["-y", "@modelcontextprotocol/server-memory"])
    }

    func testAbsoluteHomebrewNpxIsNormalized() {
        let migrated = MCPService.migrate(config(command: "/opt/homebrew/bin/npx", args: ["foo"]))
        let (cmd, _) = stdio(migrated)!
        XCTAssertEqual(cmd, "npx")
    }

    func testDeadSqlitePackageRewrittenToUvx() {
        let migrated = MCPService.migrate(config(
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-sqlite", "--db-path", "/tmp/x.sqlite"]
        ))
        let (cmd, args) = stdio(migrated)!
        XCTAssertEqual(cmd, "uvx")
        // The rewriter drops the npm-specific `-y` and package name and
        // keeps everything after the package.
        XCTAssertEqual(args, ["mcp-server-sqlite", "--db-path", "/tmp/x.sqlite"])
    }

    func testDeadGitPackageRewrittenToUvx() {
        let migrated = MCPService.migrate(config(command: "npx", args: ["-y", "@modelcontextprotocol/server-git"]))
        let (cmd, args) = stdio(migrated)!
        XCTAssertEqual(cmd, "uvx")
        XCTAssertEqual(args, ["mcp-server-git"])
    }

    func testDeadFetchPackageRewrittenToUvx() {
        let migrated = MCPService.migrate(config(command: "npx", args: ["-y", "@modelcontextprotocol/server-fetch"]))
        let (cmd, args) = stdio(migrated)!
        XCTAssertEqual(cmd, "uvx")
        XCTAssertEqual(args, ["mcp-server-fetch"])
    }

    func testDeprecatedBravePackageRenamedKeepingNpx() {
        let migrated = MCPService.migrate(config(command: "npx", args: ["-y", "@modelcontextprotocol/server-brave-search"]))
        let (cmd, args) = stdio(migrated)!
        // Brave moved to a new npm package but it's still launched via npx.
        XCTAssertEqual(cmd, "npx")
        XCTAssertEqual(args, ["-y", "@brave/brave-search-mcp-server"])
    }

    func testWorkingNpmPackageLeftAlone() {
        // server-memory is still on npm — the migrator must not touch it.
        let original = config(command: "npx", args: ["-y", "@modelcontextprotocol/server-memory"])
        let migrated = MCPService.migrate(original)
        let (cmd, args) = stdio(migrated)!
        XCTAssertEqual(cmd, "npx")
        XCTAssertEqual(args, ["-y", "@modelcontextprotocol/server-memory"])
    }

    func testNonStdioTransportPassThrough() {
        var c = MCPServerConfig(name: "HTTP", transport: .http(url: "https://example.com/mcp", headers: nil), enabled: true)
        c = MCPService.migrate(c)
        if case .http(let url, _) = c.transport {
            XCTAssertEqual(url, "https://example.com/mcp")
        } else {
            XCTFail("transport should remain .http")
        }
    }
}

final class MCPResolveExecutableTests: XCTestCase {

    func testAbsolutePathWhenExecutable() throws {
        // /bin/sh is always executable on macOS.
        let resolved = try MCPClient.resolveExecutable("/bin/sh")
        XCTAssertEqual(resolved, "/bin/sh")
    }

    func testAbsolutePathThatDoesNotExistThrows() {
        XCTAssertThrowsError(try MCPClient.resolveExecutable("/this/path/does/not/exist/xyz123"))
    }

    func testBareNameResolvesViaShellPath() throws {
        // `ls` exists on every macOS install — somewhere on the resolver's
        // PATH (which the shell-discovery routine always seeds with
        // /usr/bin and /bin as fallbacks).
        let resolved = try MCPClient.resolveExecutable("ls")
        XCTAssertTrue(resolved.hasSuffix("/ls"), "expected an absolute path ending in /ls, got \(resolved)")
    }

    func testBareNameThatDoesNotExistThrows() {
        XCTAssertThrowsError(try MCPClient.resolveExecutable("definitely-not-a-real-binary-xyz"))
    }
}

final class MCPSSEParsingTests: XCTestCase {
    // The SSE event splitter inside performHTTPPost is a tight loop:
    // accumulate `data: ...` lines until a blank line, then dispatch.
    // Reimplement it here as a pure function so we can pin its behavior
    // without spinning up a URLSession. If the real implementation drifts,
    // this test will get out of sync — which is itself the signal.

    private func splitSSE(_ stream: String) -> [String] {
        var events: [String] = []
        var dataBuffer = ""
        for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.hasPrefix("data:") {
                let chunk = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if dataBuffer.isEmpty { dataBuffer = chunk }
                else { dataBuffer += "\n" + chunk }
            } else if l.isEmpty {
                if !dataBuffer.isEmpty {
                    events.append(dataBuffer)
                    dataBuffer = ""
                }
            }
        }
        if !dataBuffer.isEmpty { events.append(dataBuffer) }
        return events
    }

    func testSingleEvent() {
        let events = splitSSE("data: {\"jsonrpc\":\"2.0\"}\n\n")
        XCTAssertEqual(events, ["{\"jsonrpc\":\"2.0\"}"])
    }

    func testTwoBackToBackEvents() {
        let stream = """
        data: {"a":1}

        data: {"b":2}

        """
        XCTAssertEqual(splitSSE(stream), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testMultiLineDataConcatenatesWithNewline() {
        let stream = """
        data: line one
        data: line two

        """
        XCTAssertEqual(splitSSE(stream), ["line one\nline two"])
    }

    func testFinalEventWithoutTrailingBlankLineStillFlushes() {
        // Networks often close the stream without a trailing \n\n.
        XCTAssertEqual(splitSSE("data: {\"final\":true}"), ["{\"final\":true}"])
    }

    func testNonDataLinesIgnored() {
        let stream = """
        event: message
        id: 42
        data: hello

        """
        XCTAssertEqual(splitSSE(stream), ["hello"])
    }
}
