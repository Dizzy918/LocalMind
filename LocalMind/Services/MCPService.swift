//
//  MCPService.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 27.06.26.
//

import Foundation

@Observable
final class MCPService: Sendable {
    private var clients: [String: MCPClient] = [:]
    private var serverConfigs: [MCPServerConfig] = []
    private let dataStore: DataStore

    var availableTools: [MCPTool] = []
    var connectionStates: [String: MCPConnectionState] = [:]

    init(dataStore: DataStore) {
        self.dataStore = dataStore
        loadConfigs()
        Task { await connectAll() }
    }

    private func loadConfigs() {
        if let data = UserDefaults.standard.data(forKey: "mcpServerConfigs"),
           let configs = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            // Migrate any old hardcoded /usr/local/bin/npx entries to bare "npx"
            // so the path resolver picks the right one for this machine.
            serverConfigs = configs.map { config in
                guard case .stdio(let command, let args, let env) = config.transport else { return config }
                if command == "/usr/local/bin/npx" || command == "/opt/homebrew/bin/npx" {
                    var fixed = config
                    fixed.transport = .stdio(command: "npx", args: args, env: env)
                    return fixed
                }
                return config
            }
            saveConfigs()
        } else {
            serverConfigs = []
        }
    }

    private func saveConfigs() {
        if let data = try? JSONEncoder().encode(serverConfigs) {
            UserDefaults.standard.set(data, forKey: "mcpServerConfigs")
        }
    }

    func connectAll() async {
        for config in serverConfigs where config.enabled {
            await connect(config: config)
        }
        await refreshTools()
    }

    func connect(config: MCPServerConfig) async {
        let client = MCPClient(config: config)
        clients[config.name] = client

        do {
            try await client.connect()
            connectionStates[config.name] = await client.connectionState
        } catch {
            connectionStates[config.name] = .failed(error.localizedDescription)
        }
    }

    func disconnect(config: MCPServerConfig) async {
        await clients[config.name]?.disconnect()
        clients.removeValue(forKey: config.name)
        connectionStates[config.name] = .disconnected
        await refreshTools()
    }

    func toggleServer(_ config: MCPServerConfig) async {
        if let index = serverConfigs.firstIndex(where: { $0.name == config.name }) {
            serverConfigs[index].enabled.toggle()
            saveConfigs()

            if serverConfigs[index].enabled {
                await connect(config: serverConfigs[index])
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
        var allTools: [MCPTool] = []
        for (name, client) in clients {
            if case .connected = await client.connectionState {
                do {
                    let tools = try await client.listTools()
                    // Prefix tool names with server name to avoid conflicts
                    let prefixedTools = tools.map { tool in
                        MCPTool(
                            name: "\(name)_\(tool.name)",
                            description: tool.description,
                            inputSchema: tool.inputSchema
                        )
                    }
                    allTools.append(contentsOf: prefixedTools)
                } catch {
                    print("MCPService: Failed to list tools from \(name): \(error)")
                }
            }
        }
        availableTools = allTools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> [MCPToolContent] {
        // Parse server name from tool name (format: "ServerName_toolName")
        let components = name.split(separator: "_", maxSplits: 1).map(String.init)
        guard components.count == 2,
              let serverName = components.first,
              let toolName = components.last,
              let client = clients[serverName] else {
            throw MCPError.notConnected
        }

        return try await client.callTool(name: toolName, arguments: arguments)
    }

    var allConfigs: [MCPServerConfig] { serverConfigs }
    var isAnyConnected: Bool { connectionStates.values.contains { if case .connected = $0 { true } else { false } } }
}