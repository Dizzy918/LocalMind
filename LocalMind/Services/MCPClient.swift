//
//  MCPClient.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 27.06.26.
//

import Foundation

actor MCPClient: Sendable {
    nonisolated let config: MCPServerConfig
    nonisolated let transport: MCPTransport

    private var state: MCPConnectionState = .disconnected
    private var pendingRequests: [JSONRPCID: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    /// Per-request timeout tasks, so a request whose server never answers
    /// fails instead of hanging forever. Cancelled the moment its response
    /// (or a transport failure) arrives.
    private var pendingTimeouts: [JSONRPCID: Task<Void, Never>] = [:]
    private var requestIDCounter: Int = 0
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // HTTP transport state (Streamable HTTP per MCP spec).
    private var httpURL: URL?
    private var httpExtraHeaders: [String: String] = [:]
    private var httpSessionID: String?
    private nonisolated let httpSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()
    private var httpInFlight: [Task<Void, Never>] = []

    /// Bounded ring buffer of recent stderr lines from the spawned MCP
    /// server, plus any transport-level diagnostics we want surfaced in
    /// the UI. Capped so a chatty server can't grow without bound.
    private var logLines: [MCPLogLine] = []
    private static let maxLogLines = 500

    /// Callback fired when a *previously-connected* client transitions to
    /// .failed on its own (process died, HTTP stream dropped, etc.). Used
    /// by MCPService to drive reconnect-with-backoff. Not called for
    /// failures inside the initial `connect()` call — those are surfaced
    /// via the throw.
    private var onUnexpectedFailure: (@Sendable (String) -> Void)?

    func setOnUnexpectedFailure(_ handler: @escaping @Sendable (String) -> Void) {
        self.onUnexpectedFailure = handler
    }

    init(config: MCPServerConfig) {
        self.config = config
        self.transport = config.transport
    }

    var connectionState: MCPConnectionState {
        get async { state }
    }

    func connect() async throws {
        // Allow reconnect after a failed attempt — was previously stuck if
        // initialize threw on a first try and never reset to disconnected.
        if case .connected = state { return }
        if case .connecting = state { return }
        state = .connecting

        do {
            switch transport {
            case .stdio(let command, let args, let env):
                try await connectStdio(command: command, args: args, env: env)
            case .http(let url, let headers):
                try await connectHTTP(url: url, headers: headers)
            }

            let initResponse = try await sendInitialize()
            try await sendInitializedNotification()
            state = .connected(serverInfo: initResponse.serverInfo, capabilities: initResponse.capabilities)
        } catch {
            state = .disconnected
            await teardownProcess()
            throw error
        }
    }

    private func teardownProcess() async {
        readerTask?.cancel()
        readerTask = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
    }

    /// MCP servers expect a `notifications/initialized` after `initialize`
    /// completes; without it, some servers refuse to respond to tools/list.
    private func sendInitializedNotification() async throws {
        let notification = JSONRPCNotification(jsonrpc: "2.0", method: "notifications/initialized", params: nil)
        let data = try encoder.encode(notification)
        let line = String(data: data, encoding: .utf8)! + "\n"
        try await writeToTransport(line)
    }

    func disconnect() async {
        readerTask?.cancel()
        readerTask = nil

        if let process = process {
            process.terminate()
            self.process = nil
        }
        stdinPipe = nil
        stdoutPipe = nil

        // Cancel any in-flight HTTP POSTs and drop session state so a later
        // reconnect starts fresh.
        for task in httpInFlight { task.cancel() }
        httpInFlight.removeAll()
        httpSessionID = nil

        // Fail anything still waiting so callers unblock instead of hanging on
        // a client we just tore down.
        failAllPending(with: MCPError.notConnected)

        state = .disconnected
    }

    func listTools() async throws -> [MCPTool] {
        let response = try await sendRequest(method: "tools/list", params: nil)
        guard let result = response.result else {
            throw MCPError.serverError("Empty tools/list response")
        }
        let data = try encoder.encode(result)
        let listResponse = try decoder.decode(MCPListToolsResponse.self, from: data)
        return listResponse.tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> [MCPToolContent] {
        var params: [String: AnyCodable] = ["name": AnyCodable(name)]
        if !arguments.isEmpty {
            params["arguments"] = AnyCodable(arguments)
        }

        let response = try await sendRequest(method: "tools/call", params: params)
        guard let result = response.result else {
            throw MCPError.serverError("Empty tools/call response")
        }
        let data = try encoder.encode(result)
        let callResponse = try decoder.decode(MCPCallToolResponse.self, from: data)
        return callResponse.content
    }

    // MARK: - Private Methods

    private func connectStdio(command: String, args: [String], env: [String: String]?) async throws {
        // Resolve the executable: if a bare name like "npx" or "node" was
        // provided, hunt down the absolute path via PATH; otherwise trust
        // the literal path. Without this the user has to type out
        // /usr/local/bin/npx or /opt/homebrew/bin/npx which differs per machine.
        let resolved = try Self.resolveExecutable(command)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = args

        // Carry through the user's PATH (discovered from a login shell so
        // version managers like nvm/fnm/volta/mise resolve) so the launched
        // process can find node, python, etc. when shelling out further.
        var mergedEnv = ProcessInfo.processInfo.environment
        let userPath = Self.userShellPath().joined(separator: ":")
        let existingPath = mergedEnv["PATH"] ?? ""
        mergedEnv["PATH"] = existingPath.isEmpty ? userPath : "\(userPath):\(existingPath)"
        if let env = env {
            mergedEnv = mergedEnv.merging(env) { _, new in new }
        }
        process.environment = mergedEnv

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe

        // If the child dies (bad package, missing binary, crash), fail any
        // in-flight requests immediately so connect() returns instead of
        // hanging forever in the initialize handshake.
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { await self?.handleProcessTermination(exitCode: code) }
        }

        do {
            try process.run()
        } catch {
            // Drain whatever stderr produced before the exec failed so the
            // user sees the real error rather than a generic NSError.
            let stderrData = try? stderrPipe.fileHandleForReading.readToEnd()
            let stderrMsg = stderrData.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = stderrMsg.isEmpty ? error.localizedDescription : stderrMsg
            throw MCPError.transportError("Failed to launch '\(resolved)': \(detail)")
        }

        startReadingStdout(stdoutPipe)
        startReadingStderr(stderrPipe)
    }

    /// Locates an executable by name using the user's real shell PATH.
    /// Returns the input unchanged if it's already an absolute path.
    static func resolveExecutable(_ command: String) throws -> String {
        if command.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else {
                throw MCPError.transportError("Not executable: \(command)")
            }
            return command
        }
        let searchPaths = userShellPath()
        for dir in searchPaths {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw MCPError.transportError("Could not find '\(command)' on PATH. Install it (e.g. `brew install node` for npx) or specify an absolute path.")
    }

    /// PATH from the user's login shell, cached. GUI apps launched from
    /// Finder/launchd get a stripped PATH that omits Homebrew, nvm, fnm,
    /// volta, mise, asdf etc. Spawning a login shell once at startup is
    /// the same trick Electron's `fix-path` and VSCode use.
    private static let _cachedShellPath: [String] = computeUserShellPath()

    static func userShellPath() -> [String] { _cachedShellPath }

    private static func computeUserShellPath() -> [String] {
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return fallback }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // -i forces interactive so .zshrc/.bashrc run; -l adds login shell
        // so .zprofile/.bash_profile run too. Both are needed because version
        // managers split their PATH exports across these files differently.
        proc.arguments = ["-ilc", "echo $PATH"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return fallback
        }

        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let discovered = output.split(separator: ":").map(String.init).filter { !$0.isEmpty }

        // Union: shell-discovered first, then the common fallbacks for anything missing.
        var seen = Set<String>()
        var result: [String] = []
        for dir in discovered + fallback where seen.insert(dir).inserted {
            result.append(dir)
        }
        return result.isEmpty ? fallback : result
    }

    private func startReadingStderr(_ pipe: Pipe) {
        // Capture server stderr into the per-client ring buffer so the UI
        // can show it on demand. Also mirrors to Xcode console for the
        // developer-debug case.
        Task.detached(priority: .utility) { [weak self] in
            let handle = pipe.fileHandleForReading
            do {
                for try await line in handle.bytes.lines {
                    if Task.isCancelled { break }
                    await self?.appendLog(.init(timestamp: Date(), source: .stderr, text: line))
                    let serverName = await self?.config.name ?? "?"
                    print("[MCP \(serverName) stderr] \(line)")
                }
            } catch {
                // Pipe closed when the process exits — expected.
            }
        }
    }

    /// Append a line to the bounded log buffer, dropping the oldest if
    /// we've hit the cap.
    private func appendLog(_ line: MCPLogLine) {
        logLines.append(line)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }

    /// Snapshot of the recent log lines for UI display.
    func recentLogs() -> [MCPLogLine] { logLines }

    /// Wipe the log buffer (UI "Clear" action).
    func clearLogs() { logLines.removeAll() }

    private func connectHTTP(url: String, headers: [String: String]?) async throws {
        guard let parsed = URL(string: url) else {
            throw MCPError.transportError("Invalid HTTP URL: \(url)")
        }
        httpURL = parsed
        httpExtraHeaders = headers ?? [:]
        httpSessionID = nil
        // No socket to open — the initialize handshake driven by connect()
        // will perform the first POST and surface any reachability errors.
    }

    private func startReadingStdout(_ pipe: Pipe) {
        readerTask = Task { [weak self] in
            guard let self = self else { return }
            let fileHandle = pipe.fileHandleForReading
            do {
                for try await line in fileHandle.bytes.lines {
                    if Task.isCancelled { break }
                    await self.handleIncomingLine(line)
                }
            } catch {
                print("MCPClient: Reader task error: \(error)")
            }
        }
    }

    private func handleIncomingLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else { return }

        do {
            // Try to decode as response first
            if let response = try? decoder.decode(JSONRPCResponse.self, from: data) {
                await handleResponse(response)
            } else if let notification = try? decoder.decode(JSONRPCNotification.self, from: data) {
                await handleNotification(notification)
            }
        } catch {
            print("MCPClient: Failed to decode message: \(error)")
        }
    }

    private func handleResponse(_ response: JSONRPCResponse) async {
        pendingTimeouts.removeValue(forKey: response.id)?.cancel()
        if let continuation = pendingRequests.removeValue(forKey: response.id) {
            continuation.resume(returning: response)
        }
    }

    /// Called when the spawned MCP server process exits. Fails any pending
    /// JSON-RPC requests so callers like connect() unblock instead of
    /// waiting forever on a process that's no longer there.
    private func handleProcessTermination(exitCode: Int32) async {
        for task in pendingTimeouts.values { task.cancel() }
        pendingTimeouts.removeAll()
        let pending = pendingRequests
        pendingRequests.removeAll()
        let msg = "Server process exited (status \(exitCode)) before responding. Check the package name and that the command is correct."
        appendLog(.init(timestamp: Date(), source: .transport, text: msg))
        let err = MCPError.transportError(msg)
        for (_, cont) in pending {
            cont.resume(throwing: err)
        }
        readerTask?.cancel()
        readerTask = nil
        if case .connected = state {
            let failureMsg = "Server process exited unexpectedly (status \(exitCode))."
            state = .failed(failureMsg)
            onUnexpectedFailure?(failureMsg)
        }
    }

    private func handleNotification(_ notification: JSONRPCNotification) async {
        // Handle server notifications (e.g., tools/list_changed)
        print("MCPClient: Received notification: \(notification.method)")
    }

    private func sendInitialize() async throws -> MCPInitializeResponse {
        let request = MCPInitializeRequest(
            protocolVersion: "2024-11-05",
            capabilities: MCPClientCapabilities(roots: MCPRootsCapability(listChanged: true), sampling: nil),
            clientInfo: MCPImplementation(name: "LocalMind", version: "1.0.0")
        )

        let params: [String: AnyCodable] = [
            "protocolVersion": AnyCodable(request.protocolVersion),
            "capabilities": AnyCodable(["roots": ["listChanged": true]]),
            "clientInfo": AnyCodable(["name": request.clientInfo.name, "version": request.clientInfo.version])
        ]

        // 20s is generous for npx cold-cache installs; anything longer is
        // almost certainly a dead handshake (wrong package, server crashed
        // silently after stdio open, etc.). We'd rather surface an error
        // than leave the UI stuck on "Connecting…" indefinitely. The timeout
        // is enforced per-request inside `sendRequest`, which cleans up the
        // pending continuation on expiry (the old TaskGroup race could leak it).
        let response = try await sendRequest(method: "initialize", params: params, timeout: 20)
        guard let result = response.result else {
            throw MCPError.serverError("Empty initialize response")
        }
        let data = try encoder.encode(result)
        return try decoder.decode(MCPInitializeResponse.self, from: data)
    }

    /// Sends a JSON-RPC request and waits for its response, failing after
    /// `timeout` seconds. Every request is timed out — not just `initialize` —
    /// because a connected-but-silent server (process alive, so the
    /// termination handler never fires) would otherwise wedge `tools/call`
    /// and `tools/list` indefinitely.
    private func sendRequest(method: String, params: [String: AnyCodable]?, timeout: Double = 60) async throws -> JSONRPCResponse {
        let id = nextRequestID()
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try encoder.encode(request)
        let jsonString = String(data: data, encoding: .utf8)! + "\n"

        try await writeToTransport(jsonString)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            pendingTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.timeoutRequest(id, method: method, seconds: timeout)
            }
        }
    }

    /// Fails a single in-flight request that outran its timeout, cleaning up
    /// both maps so nothing leaks. No-op if the response already arrived.
    private func timeoutRequest(_ id: JSONRPCID, method: String, seconds: Double) {
        pendingTimeouts.removeValue(forKey: id)
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: MCPError.transportError(
            "Timed out after \(Int(seconds))s waiting for '\(method)'. The server may have stalled or the package may not exist."
        ))
    }

    private func nextRequestID() -> JSONRPCID {
        requestIDCounter += 1
        return .number(requestIDCounter)
    }

    private func writeToTransport(_ string: String) async throws {
        guard let data = string.data(using: .utf8) else { return }

        switch transport {
        case .stdio:
            try stdinPipe?.fileHandleForWriting.write(contentsOf: data)
        case .http:
            // Fire the POST as a child task so the caller (sendRequest)
            // returns immediately and waits on its pendingRequests
            // continuation, matching the stdio model.
            let task = Task { await self.performHTTPPost(body: data) }
            httpInFlight.append(task)
        }
    }

    /// Posts a single JSON-RPC frame and routes the response back through
    /// `handleIncomingLine` so the rest of the client doesn't need to know
    /// which transport it's running on. Supports both plain JSON responses
    /// and SSE streams (which a Streamable-HTTP server can return when it
    /// wants to push multiple events for a single request).
    private func performHTTPPost(body: Data) async {
        guard let url = httpURL else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in httpExtraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if let sid = httpSessionID { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        // A bearer token from an OAuth sign-in, refreshed if it's near expiry.
        // A user-supplied Authorization header still wins, so an API key typed
        // in by hand keeps working.
        if httpExtraHeaders["Authorization"] == nil {
            let serverName = config.name
            if let token = await MCPOAuthService.shared.validToken(for: serverName) {
                req.setValue(token.authorizationHeader, forHTTPHeaderField: "Authorization")
            }
        }
        req.httpBody = body

        do {
            let (bytes, response) = try await httpSession.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { return }

            if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
                httpSessionID = sid
            }

            // 202 Accepted = notification, no body to read.
            if http.statusCode == 202 { return }
            if !(200...299).contains(http.statusCode) {
                let err = MCPError.transportError("HTTP \(http.statusCode) from server")
                failAllPending(with: err)
                return
            }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("text/event-stream") {
                // SSE: each event is `data: <json>\n\n` (multi-line data is
                // joined with a newline per the spec). We only care about
                // `data:` lines containing JSON-RPC frames.
                var dataBuffer = ""
                for try await line in bytes.lines {
                    if line.hasPrefix("data:") {
                        let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if dataBuffer.isEmpty { dataBuffer = chunk }
                        else { dataBuffer += "\n" + chunk }
                    } else if line.isEmpty {
                        if !dataBuffer.isEmpty {
                            await handleIncomingLine(dataBuffer)
                            dataBuffer = ""
                        }
                    }
                }
                if !dataBuffer.isEmpty { await handleIncomingLine(dataBuffer) }
            } else {
                // Plain JSON response — collect the whole body and dispatch.
                var collected = Data()
                for try await byte in bytes { collected.append(byte) }
                if let line = String(data: collected, encoding: .utf8) {
                    await handleIncomingLine(line)
                }
            }
        } catch {
            failAllPending(with: MCPError.transportError("HTTP request failed: \(error.localizedDescription)"))
        }
    }

    private func failAllPending(with error: Error) {
        for task in pendingTimeouts.values { task.cancel() }
        pendingTimeouts.removeAll()
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, cont) in pending { cont.resume(throwing: error) }
    }
}

enum MCPError: Error, LocalizedError, Sendable {
    case notConnected
    case notImplemented(String)
    case transportError(String)
    case decodeError(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "MCP client not connected"
        case .notImplemented(let msg): return "Not implemented: \(msg)"
        case .transportError(let msg): return "Transport error: \(msg)"
        case .decodeError(let msg): return "Decode error: \(msg)"
        case .serverError(let msg): return "Server error: \(msg)"
        }
    }
}