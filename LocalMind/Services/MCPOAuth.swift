//
//  MCPOAuth.swift
//  LocalMind
//
//  OAuth 2.1 for remote (HTTP) MCP servers.
//
//  The HTTP transport could only send static headers the user typed in by
//  hand, which works for a personal API key and not at all for the hosted
//  servers the ecosystem is moving to. Those speak the MCP authorization
//  spec: discover the authorization server, register a client dynamically,
//  run an authorization-code flow with PKCE, then send a bearer token and
//  refresh it when it expires.
//
//  The redirect comes back through the app's existing localmind:// URL scheme,
//  so there's no local HTTP server listening on a port for the callback.
//
//  Tokens live in the Keychain, never in UserDefaults or the config JSON —
//  those are readable by anything running as the user, and a leaked MCP token
//  can reach whatever the server is connected to.
//
//  The pure parts (PKCE derivation, metadata parsing, URL building) are
//  separated out so the protocol details are testable without a live server.
//

import CryptoKit
import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - PKCE

/// Proof Key for Code Exchange (RFC 7636). Required by OAuth 2.1 — it stops an
/// intercepted authorization code from being redeemed by anyone but us, which
/// matters here because the redirect travels through a URL scheme any app on
/// the machine could in principle claim.
nonisolated struct PKCEPair: Sendable, Equatable {
    let verifier: String
    let challenge: String
    let method = "S256"

    init(verifier: String? = nil) {
        let raw = verifier ?? Self.randomVerifier()
        self.verifier = raw
        self.challenge = Self.challenge(for: raw)
    }

    /// 43–128 characters from the unreserved set, per the RFC.
    static func randomVerifier(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// base64url without padding — plain base64 would break in a query string.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Server metadata

/// The subset of RFC 8414 authorization-server metadata we need.
nonisolated struct MCPOAuthMetadata: Sendable, Equatable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    let scopesSupported: [String]

    init?(json: [String: Any]) {
        guard let authorization = (json["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (json["token_endpoint"] as? String).flatMap(URL.init(string:)) else {
            return nil
        }
        self.authorizationEndpoint = authorization
        self.tokenEndpoint = token
        self.registrationEndpoint = (json["registration_endpoint"] as? String).flatMap(URL.init(string:))
        self.scopesSupported = (json["scopes_supported"] as? [String]) ?? []
    }

    /// Well-known metadata locations to try, in order. The spec moved the
    /// path around, so older servers only answer on the legacy location.
    static func discoveryURLs(for server: URL) -> [URL] {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return [] }
        let base = components.path
        var candidates: [URL] = []
        for path in ["/.well-known/oauth-authorization-server",
                     "/.well-known/openid-configuration"] {
            components.path = path
            components.query = nil
            if let url = components.url { candidates.append(url) }
            // Path-aware variant: some servers namespace the metadata under
            // the resource path rather than the host root.
            if !base.isEmpty, base != "/" {
                components.path = path + base
                if let url = components.url { candidates.append(url) }
            }
        }
        return candidates
    }
}

/// A token set as returned by the token endpoint.
nonisolated struct MCPOAuthToken: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenType: String

    /// Treated as expired slightly early so a request isn't sent with a token
    /// that dies in flight.
    func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    var authorizationHeader: String {
        "\(tokenType.isEmpty ? "Bearer" : tokenType) \(accessToken)"
    }

    init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, tokenType: String = "Bearer") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
    }

    init?(json: [String: Any], now: Date = Date()) {
        guard let access = json["access_token"] as? String else { return nil }
        self.accessToken = access
        self.refreshToken = json["refresh_token"] as? String
        self.tokenType = (json["token_type"] as? String) ?? "Bearer"
        if let lifetime = json["expires_in"] as? Double {
            self.expiresAt = now.addingTimeInterval(lifetime)
        } else if let lifetime = json["expires_in"] as? Int {
            self.expiresAt = now.addingTimeInterval(Double(lifetime))
        } else {
            self.expiresAt = nil
        }
    }
}

// MARK: - Request building

nonisolated enum MCPOAuthRequests {
    static let redirectURI = "localmind://oauth-callback"

    /// The URL the user is sent to in their browser to approve access.
    static func authorizationURL(
        metadata: MCPOAuthMetadata,
        clientID: String,
        pkce: PKCEPair,
        state: String,
        scopes: [String]
    ) -> URL? {
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state)
        ]
        let requested = scopes.isEmpty ? metadata.scopesSupported : scopes
        if !requested.isEmpty {
            items.append(URLQueryItem(name: "scope", value: requested.joined(separator: " ")))
        }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url
    }

    /// Form body for exchanging an authorization code for tokens.
    static func tokenExchangeBody(code: String, clientID: String, clientSecret: String?, verifier: String) -> String {
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ]
        if let clientSecret { fields["client_secret"] = clientSecret }
        return formEncoded(fields)
    }

    static func refreshBody(refreshToken: String, clientID: String, clientSecret: String?) -> String {
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        if let clientSecret { fields["client_secret"] = clientSecret }
        return formEncoded(fields)
    }

    /// `application/x-www-form-urlencoded`, with the character set that
    /// actually escapes `+` and `&` — `.urlQueryAllowed` leaves both intact,
    /// which silently corrupts tokens containing them.
    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    /// Pulls `code` and `state` out of the localmind://oauth-callback redirect.
    static func parseCallback(_ url: URL) -> (code: String, state: String)? {
        guard url.scheme?.lowercased() == "localmind",
              url.host?.lowercased() == "oauth-callback",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value else {
            return nil
        }
        return (code, state)
    }
}

// MARK: - Keychain

/// Minimal Keychain wrapper for OAuth tokens, keyed by server name.
nonisolated enum MCPTokenStore {
    private static let service = "com.localmind.app.mcp-oauth"

    static func save(_ token: MCPOAuthToken, for server: String) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for server: String) -> MCPOAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(MCPOAuthToken.self, from: data)
    }

    static func delete(for server: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Flow

enum MCPOAuthError: Error, LocalizedError {
    case discoveryFailed
    case registrationFailed(String)
    case authorizationFailed(String)
    case tokenExchangeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .discoveryFailed:
            return "This server didn't advertise an OAuth configuration. It may not need sign-in, or may not support it."
        case .registrationFailed(let detail):
            return "Couldn't register with the authorization server: \(detail)"
        case .authorizationFailed(let detail):
            return "Authorization failed: \(detail)"
        case .tokenExchangeFailed(let detail):
            return "Couldn't complete sign-in: \(detail)"
        case .cancelled:
            return "Sign-in was cancelled."
        }
    }
}

/// Drives the browser-based authorization flow and keeps tokens fresh.
@MainActor
final class MCPOAuthService {
    static let shared = MCPOAuthService()

    /// In-flight authorization, waiting on the browser redirect.
    private struct PendingAuthorization {
        let serverName: String
        let metadata: MCPOAuthMetadata
        let clientID: String
        let clientSecret: String?
        let pkce: PKCEPair
        let state: String
        let continuation: CheckedContinuation<MCPOAuthToken, Error>
    }

    private var pending: PendingAuthorization?
    private let session = URLSession(configuration: .ephemeral)

    /// A valid access token for the server, refreshing when it's about to
    /// expire. nil when the user has never signed in to this server.
    func validToken(for serverName: String) async -> MCPOAuthToken? {
        guard let stored = MCPTokenStore.load(for: serverName) else { return nil }
        guard stored.isExpired() else { return stored }
        guard let refresh = stored.refreshToken,
              let metadata = cachedMetadata[serverName] else { return stored }

        guard let refreshed = try? await exchange(
            body: MCPOAuthRequests.refreshBody(
                refreshToken: refresh,
                clientID: cachedClientID[serverName] ?? "",
                clientSecret: cachedClientSecret[serverName]
            ),
            at: metadata.tokenEndpoint
        ) else {
            return stored
        }
        // Servers often omit the refresh token on refresh; keep the old one so
        // the next expiry can still be handled without a browser round trip.
        var updated = refreshed
        if updated.refreshToken == nil { updated.refreshToken = refresh }
        MCPTokenStore.save(updated, for: serverName)
        return updated
    }

    private var cachedMetadata: [String: MCPOAuthMetadata] = [:]
    private var cachedClientID: [String: String] = [:]
    private var cachedClientSecret: [String: String] = [:]

    /// Runs the full flow: discover, register, open the browser, wait for the
    /// redirect, exchange the code. Returns the stored token.
    @discardableResult
    func signIn(serverName: String, serverURL: URL) async throws -> MCPOAuthToken {
        guard let metadata = await discoverMetadata(for: serverURL) else {
            throw MCPOAuthError.discoveryFailed
        }
        cachedMetadata[serverName] = metadata

        let (clientID, clientSecret) = try await clientCredentials(for: serverName, metadata: metadata)
        cachedClientID[serverName] = clientID
        cachedClientSecret[serverName] = clientSecret

        let pkce = PKCEPair()
        let state = PKCEPair.randomVerifier(byteCount: 16)
        guard let authorizationURL = MCPOAuthRequests.authorizationURL(
            metadata: metadata,
            clientID: clientID,
            pkce: pkce,
            state: state,
            scopes: []
        ) else {
            throw MCPOAuthError.authorizationFailed("Couldn't build the authorization URL.")
        }

        // Abandon any earlier attempt rather than leaving its caller hanging.
        pending?.continuation.resume(throwing: MCPOAuthError.cancelled)

        let token: MCPOAuthToken = try await withCheckedThrowingContinuation { continuation in
            pending = PendingAuthorization(
                serverName: serverName,
                metadata: metadata,
                clientID: clientID,
                clientSecret: clientSecret,
                pkce: pkce,
                state: state,
                continuation: continuation
            )
            #if os(macOS)
            NSWorkspace.shared.open(authorizationURL)
            #endif
        }

        MCPTokenStore.save(token, for: serverName)
        return token
    }

    /// Called by the app's URL handler when the browser redirects back.
    /// Returns whether the URL was an OAuth callback we were waiting for.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard let (code, state) = MCPOAuthRequests.parseCallback(url),
              let awaiting = pending else { return false }
        // A mismatched state means this redirect isn't the one we started —
        // the CSRF check the flow exists to provide.
        guard state == awaiting.state else {
            pending = nil
            awaiting.continuation.resume(throwing: MCPOAuthError.authorizationFailed("The redirect didn't match the request."))
            return true
        }
        pending = nil

        Task {
            do {
                let token = try await exchange(
                    body: MCPOAuthRequests.tokenExchangeBody(
                        code: code,
                        clientID: awaiting.clientID,
                        clientSecret: awaiting.clientSecret,
                        verifier: awaiting.pkce.verifier
                    ),
                    at: awaiting.metadata.tokenEndpoint
                )
                awaiting.continuation.resume(returning: token)
            } catch {
                awaiting.continuation.resume(throwing: error)
            }
        }
        return true
    }

    func signOut(serverName: String) {
        MCPTokenStore.delete(for: serverName)
        cachedMetadata[serverName] = nil
        cachedClientID[serverName] = nil
        cachedClientSecret[serverName] = nil
    }

    func isSignedIn(serverName: String) -> Bool {
        MCPTokenStore.load(for: serverName) != nil
    }

    // MARK: - Steps

    private func discoverMetadata(for serverURL: URL) async -> MCPOAuthMetadata? {
        for candidate in MCPOAuthMetadata.discoveryURLs(for: serverURL) {
            guard let (data, response) = try? await session.data(from: candidate),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let metadata = MCPOAuthMetadata(json: json) else { continue }
            return metadata
        }
        return nil
    }

    /// Reuses a previously registered client, otherwise registers one
    /// dynamically (RFC 7591) so the user never has to create an app
    /// registration by hand.
    private func clientCredentials(for serverName: String, metadata: MCPOAuthMetadata) async throws -> (String, String?) {
        let key = "mcpOAuthClient.\(serverName)"
        if let saved = UserDefaults.standard.dictionary(forKey: key),
           let id = saved["client_id"] as? String {
            return (id, saved["client_secret"] as? String)
        }

        guard let registrationEndpoint = metadata.registrationEndpoint else {
            throw MCPOAuthError.registrationFailed("The server doesn't support dynamic registration, and no client ID was configured.")
        }

        var request = URLRequest(url: registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_name": "LocalMind",
            "redirect_uris": [MCPOAuthRequests.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ])

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["client_id"] as? String else {
            throw MCPOAuthError.registrationFailed("The authorization server rejected the registration.")
        }

        let secret = json["client_secret"] as? String
        // Only the client id/secret pair lives here; tokens go to the Keychain.
        UserDefaults.standard.set(
            ["client_id": clientID, "client_secret": secret as Any],
            forKey: key
        )
        return (clientID, secret)
    }

    private func exchange(body: String, at endpoint: URL) async throws -> MCPOAuthToken {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            throw MCPOAuthError.tokenExchangeFailed("The token endpoint couldn't be reached.")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "HTTP \(http.statusCode)"
            throw MCPOAuthError.tokenExchangeFailed(detail)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = MCPOAuthToken(json: json) else {
            throw MCPOAuthError.tokenExchangeFailed("The token response couldn't be read.")
        }
        return token
    }
}
