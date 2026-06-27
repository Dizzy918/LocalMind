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
    private var requestIDCounter: Int = 0
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

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

        // Always carry through the user's PATH so npx can locate node, etc.
        var mergedEnv = ProcessInfo.processInfo.environment
        if let env = env {
            mergedEnv = mergedEnv.merging(env) { _, new in new }
        }
        // Common Homebrew prefixes that GUI apps don't get by default.
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let currentPath = mergedEnv["PATH"] ?? ""
        let pathParts = currentPath.split(separator: ":").map(String.init)
        let missingPaths = extraPaths.filter { !pathParts.contains($0) }
        if !missingPaths.isEmpty {
            mergedEnv["PATH"] = (missingPaths + pathParts).joined(separator: ":")
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

        do {
            try process.run()
        } catch {
            throw MCPError.transportError("Failed to launch '\(resolved)': \(error.localizedDescription)")
        }

        startReadingStdout(stdoutPipe)
    }

    /// Locates an executable by name on common macOS install paths.
    /// Returns the input unchanged if it's already an absolute path.
    static func resolveExecutable(_ command: String) throws -> String {
        if command.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else {
                throw MCPError.transportError("Not executable: \(command)")
            }
            return command
        }
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in searchPaths {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw MCPError.transportError("Could not find '\(command)' in \(searchPaths.joined(separator: ", ")). Install it or use the absolute path.")
    }

    private func connectHTTP(url: String, headers: [String: String]?) async throws {
        // HTTP/SSE transport implementation would go here
        // For now, throw not implemented
        throw MCPError.notImplemented("HTTP transport not yet implemented")
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
        if let continuation = pendingRequests.removeValue(forKey: response.id) {
            continuation.resume(returning: response)
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

        let response = try await sendRequest(method: "initialize", params: params)
        guard let result = response.result else {
            throw MCPError.serverError("Empty initialize response")
        }
        let data = try encoder.encode(result)
        return try decoder.decode(MCPInitializeResponse.self, from: data)
    }

    private func sendRequest(method: String, params: [String: AnyCodable]?) async throws -> JSONRPCResponse {
        let id = nextRequestID()
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try encoder.encode(request)
        let jsonString = String(data: data, encoding: .utf8)! + "\n"

        try await writeToTransport(jsonString)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
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
            // HTTP transport would use URLSession here
            throw MCPError.notImplemented("HTTP transport not yet implemented")
        }
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