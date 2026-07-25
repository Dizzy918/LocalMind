//
//  OAuthAndInsightsTests.swift
//  LocalMindTests
//
//  Covers the pure, protocol-level parts of MCP OAuth (PKCE, metadata
//  discovery, request building, token lifetime) and the usage-statistics
//  arithmetic. Both are deliberately separated from their I/O so they can be
//  verified without a live authorization server or a populated app.
//

import XCTest
@testable import LocalMind

// MARK: - PKCE

final class PKCETests: XCTestCase {

    func testChallengeMatchesRFC7636Example() {
        // The worked example from RFC 7636 appendix B — if this passes, the
        // SHA-256 + base64url derivation is right.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCEPair.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testChallengeIsBase64URLWithoutPadding() {
        let pair = PKCEPair()
        XCTAssertFalse(pair.challenge.contains("="), "padding would be rejected in a query string")
        XCTAssertFalse(pair.challenge.contains("+"))
        XCTAssertFalse(pair.challenge.contains("/"))
        XCTAssertEqual(pair.method, "S256")
    }

    func testVerifiersAreUnique() {
        let first = PKCEPair()
        let second = PKCEPair()
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertNotEqual(first.challenge, second.challenge)
    }

    func testVerifierLengthIsWithinSpec() {
        // RFC 7636 requires 43–128 characters.
        let verifier = PKCEPair().verifier
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
    }
}

// MARK: - Discovery & metadata

final class MCPOAuthMetadataTests: XCTestCase {

    func testParsesRequiredEndpoints() throws {
        let metadata = try XCTUnwrap(MCPOAuthMetadata(json: [
            "authorization_endpoint": "https://auth.example.com/authorize",
            "token_endpoint": "https://auth.example.com/token",
            "registration_endpoint": "https://auth.example.com/register",
            "scopes_supported": ["mcp.read", "mcp.write"]
        ]))
        XCTAssertEqual(metadata.authorizationEndpoint.absoluteString, "https://auth.example.com/authorize")
        XCTAssertEqual(metadata.tokenEndpoint.absoluteString, "https://auth.example.com/token")
        XCTAssertEqual(metadata.registrationEndpoint?.absoluteString, "https://auth.example.com/register")
        XCTAssertEqual(metadata.scopesSupported, ["mcp.read", "mcp.write"])
    }

    func testRejectsMetadataMissingEndpoints() {
        XCTAssertNil(MCPOAuthMetadata(json: ["authorization_endpoint": "https://a.example.com/authorize"]))
        XCTAssertNil(MCPOAuthMetadata(json: [:]))
    }

    func testRegistrationEndpointIsOptional() throws {
        let metadata = try XCTUnwrap(MCPOAuthMetadata(json: [
            "authorization_endpoint": "https://a.example.com/authorize",
            "token_endpoint": "https://a.example.com/token"
        ]))
        XCTAssertNil(metadata.registrationEndpoint)
    }

    func testDiscoveryTriesRootAndPathScopedLocations() throws {
        let server = try XCTUnwrap(URL(string: "https://mcp.example.com/servers/notes"))
        let urls = MCPOAuthMetadata.discoveryURLs(for: server).map(\.absoluteString)

        XCTAssertTrue(urls.contains("https://mcp.example.com/.well-known/oauth-authorization-server"))
        // Servers that namespace metadata under the resource path need the
        // path-aware variant, or discovery silently fails against them.
        XCTAssertTrue(urls.contains("https://mcp.example.com/.well-known/oauth-authorization-server/servers/notes"))
    }

    func testDiscoveryHandlesRootServerURL() throws {
        let server = try XCTUnwrap(URL(string: "https://mcp.example.com"))
        let urls = MCPOAuthMetadata.discoveryURLs(for: server)
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString.contains(".well-known") })
    }
}

// MARK: - Request building

final class MCPOAuthRequestTests: XCTestCase {

    private func metadata() -> MCPOAuthMetadata {
        MCPOAuthMetadata(json: [
            "authorization_endpoint": "https://auth.example.com/authorize",
            "token_endpoint": "https://auth.example.com/token"
        ])!
    }

    func testAuthorizationURLCarriesPKCEAndState() throws {
        let pkce = PKCEPair(verifier: "verifier-under-test-value-that-is-long-enough")
        let url = try XCTUnwrap(MCPOAuthRequests.authorizationURL(
            metadata: metadata(),
            clientID: "client-123",
            pkce: pkce,
            state: "state-abc",
            scopes: ["mcp.read"]
        ))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "client-123")
        XCTAssertEqual(value("code_challenge"), pkce.challenge)
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), "state-abc")
        XCTAssertEqual(value("scope"), "mcp.read")
        XCTAssertEqual(value("redirect_uri"), "localmind://oauth-callback")
        // The verifier itself must never travel to the authorization endpoint.
        XCTAssertFalse(url.absoluteString.contains(pkce.verifier))
    }

    func testAuthorizationURLFallsBackToAdvertisedScopes() throws {
        let metadata = MCPOAuthMetadata(json: [
            "authorization_endpoint": "https://auth.example.com/authorize",
            "token_endpoint": "https://auth.example.com/token",
            "scopes_supported": ["a", "b"]
        ])!
        let url = try XCTUnwrap(MCPOAuthRequests.authorizationURL(
            metadata: metadata, clientID: "c", pkce: PKCEPair(), state: "s", scopes: []
        ))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "a b")
    }

    func testTokenExchangeBodyIncludesVerifierNotChallenge() {
        let body = MCPOAuthRequests.tokenExchangeBody(
            code: "auth-code",
            clientID: "client-123",
            clientSecret: nil,
            verifier: "the-verifier"
        )
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=auth-code"))
        XCTAssertTrue(body.contains("code_verifier=the-verifier"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testRefreshBodyUsesRefreshGrant() {
        let body = MCPOAuthRequests.refreshBody(refreshToken: "r1", clientID: "c1", clientSecret: "s1")
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=r1"))
        XCTAssertTrue(body.contains("client_secret=s1"))
    }

    func testFormEncodingEscapesReservedCharacters() {
        // `.urlQueryAllowed` leaves + and & intact, which would corrupt a token
        // containing either — this is the reason for the custom character set.
        let encoded = MCPOAuthRequests.formEncoded(["token": "a+b&c=d e"])
        XCTAssertEqual(encoded, "token=a%2Bb%26c%3Dd%20e")
    }

    func testCallbackParsingExtractsCodeAndState() throws {
        let url = try XCTUnwrap(URL(string: "localmind://oauth-callback?code=abc&state=xyz"))
        let parsed = try XCTUnwrap(MCPOAuthRequests.parseCallback(url))
        XCTAssertEqual(parsed.code, "abc")
        XCTAssertEqual(parsed.state, "xyz")
    }

    func testCallbackParsingRejectsOtherURLs() throws {
        // The app's other localmind:// routes must not be mistaken for a
        // redirect, or a normal "ask" would be swallowed by the OAuth handler.
        XCTAssertNil(MCPOAuthRequests.parseCallback(URL(string: "localmind://ask?prompt=hi")!))
        XCTAssertNil(MCPOAuthRequests.parseCallback(URL(string: "localmind://oauth-callback?code=only")!))
        XCTAssertNil(MCPOAuthRequests.parseCallback(URL(string: "https://example.com/oauth-callback?code=a&state=b")!))
    }
}

// MARK: - Token lifetime

final class MCPOAuthTokenTests: XCTestCase {

    func testTokenParsesExpiryFromLifetime() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let token = try XCTUnwrap(MCPOAuthToken(json: [
            "access_token": "at", "refresh_token": "rt", "expires_in": 3600, "token_type": "Bearer"
        ], now: now))
        XCTAssertEqual(token.accessToken, "at")
        XCTAssertEqual(token.refreshToken, "rt")
        XCTAssertEqual(token.expiresAt?.timeIntervalSince1970 ?? 0, 1_003_600, accuracy: 1)
    }

    func testTokenWithoutExpiryNeverLooksExpired() throws {
        let token = try XCTUnwrap(MCPOAuthToken(json: ["access_token": "at"]))
        XCTAssertFalse(token.isExpired())
    }

    func testTokenExpiresEarlyByTheLeeway() {
        let now = Date()
        // 30s of life left, but the 60s leeway should treat it as expired so a
        // request isn't sent with a token that dies mid-flight.
        let token = MCPOAuthToken(accessToken: "at", expiresAt: now.addingTimeInterval(30))
        XCTAssertTrue(token.isExpired(now: now, leeway: 60))
        XCTAssertFalse(token.isExpired(now: now, leeway: 10))
    }

    func testAuthorizationHeaderDefaultsToBearer() {
        XCTAssertEqual(MCPOAuthToken(accessToken: "abc", tokenType: "").authorizationHeader, "Bearer abc")
        XCTAssertEqual(MCPOAuthToken(accessToken: "abc", tokenType: "DPoP").authorizationHeader, "DPoP abc")
    }

    func testTokenRoundTripsThroughCodable() throws {
        let token = MCPOAuthToken(accessToken: "a", refreshToken: "r", expiresAt: Date(), tokenType: "Bearer")
        let decoded = try JSONDecoder().decode(MCPOAuthToken.self, from: JSONEncoder().encode(token))
        XCTAssertEqual(decoded.accessToken, token.accessToken)
        XCTAssertEqual(decoded.refreshToken, token.refreshToken)
    }
}

// MARK: - Usage insights

final class UsageInsightsTests: XCTestCase {

    private func assistant(
        model: String?,
        tps: Double? = nil,
        seconds: Double? = nil,
        completionTokens: Int? = nil,
        agent: String? = nil,
        at date: Date = Date()
    ) -> ChatMessage {
        var message = ChatMessage(role: .assistant, content: "answer", timestamp: date)
        message.modelUsed = model
        message.tokensPerSecond = tps
        message.generationSeconds = seconds
        message.completionTokens = completionTokens
        message.agentName = agent
        return message
    }

    func testEmptyHistoryProducesEmptyInsights() {
        let insights = UsageInsights.compute(from: [])
        XCTAssertEqual(insights.totalConversations, 0)
        XCTAssertEqual(insights.assistantMessages, 0)
        XCTAssertNil(insights.averageTokensPerSecond)
        XCTAssertFalse(insights.hasMeasuredTokens)
    }

    func testCountsMessagesAndConversations() {
        let convo = Conversation(title: "t", messages: [
            ChatMessage(role: .user, content: "q"),
            assistant(model: "qwen3:8b")
        ])
        let insights = UsageInsights.compute(from: [convo])
        XCTAssertEqual(insights.totalConversations, 1)
        XCTAssertEqual(insights.totalMessages, 2)
        XCTAssertEqual(insights.assistantMessages, 1, "user turns aren't answers")
    }

    func testGroupsByModelAndAveragesThroughput() throws {
        let convo = Conversation(title: "t", messages: [
            assistant(model: "fast", tps: 20),
            assistant(model: "fast", tps: 40),
            assistant(model: "slow", tps: 5)
        ])
        let insights = UsageInsights.compute(from: [convo])

        // Sorted by volume, so the most-used model reads first.
        XCTAssertEqual(insights.models.first?.name, "fast")
        XCTAssertEqual(insights.models.first?.messages, 2)
        XCTAssertEqual(try XCTUnwrap(insights.models.first?.averageTokensPerSecond), 30, accuracy: 0.001)
    }

    func testUnattributedAnswersGroupUnderUnknown() {
        let insights = UsageInsights.compute(from: [
            Conversation(title: "t", messages: [assistant(model: nil)])
        ])
        XCTAssertEqual(insights.models.first?.name, "Unknown")
    }

    func testOnlyMeasuredTokensAreCounted() {
        let convo = Conversation(title: "t", messages: [
            assistant(model: "m", completionTokens: 100),
            assistant(model: "m", completionTokens: nil)   // estimated only
        ])
        let insights = UsageInsights.compute(from: [convo])
        // The estimated answer must not contribute a fabricated number.
        XCTAssertEqual(insights.measuredCompletionTokens, 100)
        XCTAssertTrue(insights.hasMeasuredTokens)
    }

    func testNoMeasuredTokensLeavesTheTotalNil() {
        let insights = UsageInsights.compute(from: [
            Conversation(title: "t", messages: [assistant(model: "m", tps: 12)])
        ])
        XCTAssertNil(insights.measuredCompletionTokens,
                     "reporting 0 would imply the backend measured zero tokens")
        XCTAssertFalse(insights.hasMeasuredTokens)
    }

    func testSumsGenerationTime() {
        let insights = UsageInsights.compute(from: [
            Conversation(title: "t", messages: [
                assistant(model: "m", seconds: 1.5),
                assistant(model: "m", seconds: 2.5)
            ])
        ])
        XCTAssertEqual(insights.totalGenerationSeconds, 4.0, accuracy: 0.001)
    }

    func testGroupsByAgent() {
        let insights = UsageInsights.compute(from: [
            Conversation(title: "t", messages: [
                assistant(model: "m", agent: "Coder"),
                assistant(model: "m", agent: "Coder"),
                assistant(model: "m", agent: "Writer"),
                assistant(model: "m")           // no agent — excluded
            ])
        ])
        XCTAssertEqual(insights.agents.count, 2)
        XCTAssertEqual(insights.agents.first?.name, "Coder")
        XCTAssertEqual(insights.agents.first?.messages, 2)
    }

    func testBusiestDayPicksTheHighestCount() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 9)))
        let day2 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 9)))

        let insights = UsageInsights.compute(from: [
            Conversation(title: "t", messages: [
                assistant(model: "m", at: day1),
                assistant(model: "m", at: day2),
                assistant(model: "m", at: day2)
            ])
        ], calendar: calendar)

        let busiest = try XCTUnwrap(insights.busiestDay)
        XCTAssertEqual(busiest.messages, 2)
        XCTAssertEqual(calendar.component(.day, from: busiest.day), 2)
    }
}
