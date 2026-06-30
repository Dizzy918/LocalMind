//
//  MCPService.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 27.06.26.
//

import Foundation

/// MainActor-isolated because all consumers (SwiftUI views, AIServiceManager
/// from main actor) read its observable state on the main actor. The
/// previous `Sendable` declaration on a mutable class was a lie that
/// happened to compile.
@Observable
@MainActor
final class MCPService {
    private var clients: [String: MCPClient] = [:]
    private var serverConfigs: [MCPServerConfig] = []
    private let dataStore: DataStore

    var availableTools: [MCPTool] = []
    var connectionStates: [String: MCPConnectionState] = [:]

    /// Maps the *exposed* tool name (server-namespaced, model-safe) back to
    /// the originating server and the server's raw tool name. Built when
    /// `refreshTools` runs so we don't have to parse a separator out of
    /// the exposed name — that's how the old `_`-split broke when a server
    /// name happened to contain an underscore.
    private var toolRoute: [String: (serverName: String, originalName: String)] = [:]

    /// Per-server set of *raw* tool names the user has hidden. Filtered
    /// out of `availableTools` (so the model never sees them) but the
    /// underlying server still advertises them, so re-enabling is free.
    private var disabledTools: [String: Set<String>] = [:]

    /// All tools (enabled + disabled) per server. Drives the per-tool
    /// toggle sheet so it can show greyed-out rows for disabled ones.
    private(set) var allToolsByServer: [String: [MCPTool]] = [:]

    /// Scheduled reconnect tasks, keyed by server name. Canceled when the
    /// user disables a server or a connect attempt finally succeeds.
    private var retryTasks: [String: Task<Void, Never>] = [:]
    /// How many consecutive failures we've seen per server — used to pick
    /// the next backoff bucket.
    private var retryAttempts: [String: Int] = [:]
    /// Backoff schedule (seconds). After exhausting the list we cap at the
    /// last entry, so a long-down server polls forever at the slow rate.
    private static let backoffSchedule: [UInt64] = [5, 15, 60, 300]

    init(dataStore: DataStore) {
        self.dataStore = dataStore
        loadConfigs()
        loadDisabledTools()
        Task { await connectAll() }
    }

    private func loadDisabledTools() {
        guard let data = UserDefaults.standard.data(forKey: "mcpDisabledTools"),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return
        }
        disabledTools = decoded.mapValues(Set.init)
    }

    private func saveDisabledTools() {
        let serializable = disabledTools.mapValues { Array($0).sorted() }
        if let data = try? JSONEncoder().encode(serializable) {
            UserDefaults.standard.set(data, forKey: "mcpDisabledTools")
        }
    }

    private func loadConfigs() {
        if let data = UserDefaults.standard.data(forKey: "mcpServerConfigs"),
           let configs = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            serverConfigs = configs.map(Self.migrate)
            saveConfigs()
        } else {
            serverConfigs = []
        }
    }

    /// Cleans up older saved entries that point at things that no longer
    /// work: hardcoded npx paths, and the npm packages that upstream MCP
    /// removed (sqlite/git/fetch are now Python-only via uvx).
    // Internal (not private) so unit tests can call it directly. Still
    // namespaced under MCPService so no semantic surface change.
    nonisolated static func migrate(_ config: MCPServerConfig) -> MCPServerConfig {
        guard case .stdio(let command, let args, let env) = config.transport else { return config }

        var newCommand = command
        var newArgs = args

        // 1. Normalize absolute npx paths so the runtime resolver picks the
        //    right one for this machine.
        if command == "/usr/local/bin/npx" || command == "/opt/homebrew/bin/npx" {
            newCommand = "npx"
        }

        // 2. Rewrite removed-from-npm packages to their uvx equivalents.
        //    Pattern: `npx -y @modelcontextprotocol/server-X  …rest`  →
        //             `uvx mcp-server-X …rest`
        let deadPackages: [String: String] = [
            "@modelcontextprotocol/server-sqlite": "mcp-server-sqlite",
            "@modelcontextprotocol/server-git": "mcp-server-git",
            "@modelcontextprotocol/server-fetch": "mcp-server-fetch"
        ]
        if newCommand == "npx",
           let pkgIndex = newArgs.firstIndex(where: { deadPackages.keys.contains($0) }) {
            let pkg = newArgs[pkgIndex]
            let rest = Array(newArgs[(pkgIndex + 1)...])
            newCommand = "uvx"
            newArgs = [deadPackages[pkg]!] + rest
        }

        var fixed = config
        fixed.transport = .stdio(command: newCommand, args: newArgs, env: env)
        return fixed
    }

    private func saveConfigs() {
        if let data = try? JSONEncoder().encode(serverConfigs) {
            UserDefaults.standard.set(data, forKey: "mcpServerConfigs")
        }
    }

    func connectAll() async {
        // Parallel — one slow/dead server (e.g. npx fetching a missing
        // package) used to block the whole sidebar from coming up.
        await withTaskGroup(of: Void.self) { group in
            for config in serverConfigs where config.enabled {
                group.addTask { await self.connect(config: config) }
            }
        }
        await refreshTools()
    }

    func connect(config: MCPServerConfig) async {
        let client = MCPClient(config: config)
        clients[config.name] = client

        // When a long-lived stdio child dies after we were already
        // connected, the client transitions to .failed on its own — but
        // MCPService also needs to know so it can sync state and kick off
        // a reconnect.
        let serverName = config.name
        await client.setOnUnexpectedFailure { [weak self] message in
            Task { @MainActor in
                guard let self = self else { return }
                self.connectionStates[serverName] = .failed(message)
                await self.refreshTools()
                if let cfg = self.serverConfigs.first(where: { $0.name == serverName && $0.enabled }) {
                    self.scheduleRetry(for: cfg)
                }
            }
        }

        do {
            try await client.connect()
            connectionStates[config.name] = await client.connectionState
            // Success — drop any backoff state so the next failure starts fresh.
            retryAttempts.removeValue(forKey: config.name)
            retryTasks.removeValue(forKey: config.name)?.cancel()
        } catch {
            connectionStates[config.name] = .failed(error.localizedDescription)
            scheduleRetry(for: config)
        }
    }

    func disconnect(config: MCPServerConfig) async {
        retryTasks.removeValue(forKey: config.name)?.cancel()
        retryAttempts.removeValue(forKey: config.name)
        await clients[config.name]?.disconnect()
        clients.removeValue(forKey: config.name)
        connectionStates[config.name] = .disconnected
        await refreshTools()
    }

    /// Schedule the next connect attempt with exponential backoff. Replaces
    /// any pending retry for the same server.
    private func scheduleRetry(for config: MCPServerConfig) {
        retryTasks[config.name]?.cancel()

        let attempts = retryAttempts[config.name] ?? 0
        let bucket = min(attempts, Self.backoffSchedule.count - 1)
        let delay = Self.backoffSchedule[bucket]
        retryAttempts[config.name] = attempts + 1

        let serverName = config.name
        retryTasks[serverName] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            } catch {
                return // canceled — user toggled off or replaced the schedule.
            }
            guard let self = self else { return }
            // Only retry if the user hasn't disabled the server in the meantime.
            guard self.serverConfigs.first(where: { $0.name == serverName })?.enabled == true else { return }
            await self.connect(config: config)
            await self.refreshTools()
        }
    }

    func toggleServer(_ config: MCPServerConfig) async {
        if let index = serverConfigs.firstIndex(where: { $0.name == config.name }) {
            serverConfigs[index].enabled.toggle()
            saveConfigs()

            if serverConfigs[index].enabled {
                await connect(config: serverConfigs[index])
                await refreshTools()
            } else {
                await disconnect(config: config)
            }
        }
    }

    func addServer(_ config: MCPServerConfig) async {
        // Dedupe by name — replaces an existing entry instead of producing
        // two rows with the same id.
        if let existingIndex = serverConfigs.firstIndex(where: { $0.name == config.name }) {
            await disconnect(config: serverConfigs[existingIndex])
            serverConfigs[existingIndex] = config
        } else {
            serverConfigs.append(config)
        }
        saveConfigs()
        if config.enabled {
            await connect(config: config)
            await refreshTools()
        }
    }

    /// Force a fresh connection attempt — useful for the user's "Reconnect"
    /// action on a failed entry.
    func reconnect(_ config: MCPServerConfig) async {
        await disconnect(config: config)
        await connect(config: config)
        await refreshTools()
    }

    /// Number of tools currently exposed by a given server.
    func toolCount(for serverName: String) -> Int {
        availableTools.filter { $0.name.hasPrefix("\(serverName)_") }.count
    }

    func removeServer(_ config: MCPServerConfig) async {
        await disconnect(config: config)
        serverConfigs.removeAll { $0.name == config.name }
        saveConfigs()
        await refreshTools()
    }

    func refreshTools() async {
        var enabledTools: [MCPTool] = []
        var allByServer: [String: [MCPTool]] = [:]
        var route: [String: (serverName: String, originalName: String)] = [:]
        for (serverName, client) in clients {
            if case .connected = await client.connectionState {
                do {
                    let tools = try await client.listTools()
                    allByServer[serverName] = tools
                    let slug = Self.slug(serverName)
                    let disabled = disabledTools[serverName] ?? []
                    for tool in tools {
                        let exposedName = "\(slug)__\(tool.name)"
                        // Always populate the route map so callTool works for
                        // any tool the user re-enables without needing a full
                        // refresh — only the *advertised* list is filtered.
                        route[exposedName] = (serverName, tool.name)
                        if disabled.contains(tool.name) { continue }
                        enabledTools.append(MCPTool(
                            name: exposedName,
                            description: tool.description,
                            inputSchema: tool.inputSchema
                        ))
                    }
                } catch {
                    print("MCPService: Failed to list tools from \(serverName): \(error)")
                }
            }
        }
        availableTools = enabledTools
        toolRoute = route
        allToolsByServer = allByServer
    }

    /// True when the named tool (raw, server-native) is currently exposed
    /// to the model.
    func isToolEnabled(server: String, tool: String) -> Bool {
        !(disabledTools[server]?.contains(tool) ?? false)
    }

    /// Toggle a single tool on/off. Cheap — just updates the disabled set
    /// and re-derives `availableTools` so the model picker updates.
    func setToolEnabled(_ enabled: Bool, server: String, tool: String) async {
        var set = disabledTools[server] ?? []
        if enabled { set.remove(tool) } else { set.insert(tool) }
        if set.isEmpty { disabledTools.removeValue(forKey: server) }
        else { disabledTools[server] = set }
        saveDisabledTools()
        await refreshTools()
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> [MCPToolContent] {
        guard let route = toolRoute[name], let client = clients[route.serverName] else {
            throw MCPError.notConnected
        }
        return try await client.callTool(name: route.originalName, arguments: arguments)
    }

    /// Lowercase, hyphen-separated, alphanumeric-and-hyphen only — produces
    /// model-safe tool name prefixes from human-readable server names like
    /// "Brave Search" → "brave-search".
    nonisolated static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                out.append(c)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "server" : trimmed
    }

    /// Snapshot of recent stderr + transport lines for a given server.
    /// Returns an empty array if the server has no client yet (e.g. it's
    /// been disabled since launch).
    func recentLogs(for serverName: String) async -> [MCPLogLine] {
        guard let client = clients[serverName] else { return [] }
        return await client.recentLogs()
    }

    func clearLogs(for serverName: String) async {
        await clients[serverName]?.clearLogs()
    }

    var allConfigs: [MCPServerConfig] { serverConfigs }
    var isAnyConnected: Bool { connectionStates.values.contains { if case .connected = $0 { true } else { false } } }
}