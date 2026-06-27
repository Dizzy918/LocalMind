//
//  MCPSettingsView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 27.06.26.
//

import SwiftUI

struct MCPSettingsView: View {
    let mcpService: MCPService
    
    @State private var showingAddServer = false
    @State private var editingConfig: MCPServerConfig?
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("MCP Servers")
                    .font(AppTheme.Typography.title2)
                Spacer()
                Button(action: { showingAddServer = true }) {
                    Label("Add Server", systemImage: "plus")
                }
            }
            
            if mcpService.allConfigs.isEmpty {
                Text("No MCP servers configured. Add one to enable tool access for AI models.")
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.vertical, AppTheme.Spacing.lg)
            } else {
                List {
                    ForEach(mcpService.allConfigs) { config in
                        MCPServerRowView(
                            config: config,
                            state: mcpService.connectionStates[config.name] ?? .disconnected,
                            onToggle: { await mcpService.toggleServer(config) },
                            onEdit: { editingConfig = config },
                            onDelete: { await mcpService.removeServer(config) }
                        )
                    }
                }
                .listStyle(.bordered)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .sheet(isPresented: $showingAddServer) {
            AddMCPServerView(mcpService: mcpService) {
                showingAddServer = false
            }
        }
        .sheet(item: $editingConfig) { config in
            EditMCPServerView(mcpService: mcpService, config: config) {
                editingConfig = nil
            }
        }
    }
}

struct MCPServerRowView: View {
    let config: MCPServerConfig
    let state: MCPConnectionState
    let onToggle: () async -> Void
    let onEdit: () -> Void
    let onDelete: () async -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(config.name)
                        .font(AppTheme.Typography.headline)
                    ConnectionStatusBadge(state: state)
                }
                
                Text(transportDescription)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { config.enabled },
                set: { _ in Task { await onToggle() } }
            ))
            .labelsHidden()
            
            Menu {
                Button("Edit", action: onEdit)
                Button("Delete", role: .destructive) {
                    Task { await onDelete() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 4)
    }
    
    private var transportDescription: String {
        switch config.transport {
        case .stdio(let command, let args, _):
            return "stdio: \(command) \(args.joined(separator: " "))"
        case .http(let url, _):
            return "http: \(url)"
        }
    }
}

struct ConnectionStatusBadge: View {
    let state: MCPConnectionState
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(statusColor)
        }
    }
    
    private var statusColor: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }
    
    private var statusText: String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .failed(let message): return "Error: \(message)"
        }
    }
}

struct AddMCPServerView: View {
    let mcpService: MCPService
    let onDismiss: () -> Void
    
    @State private var name = ""
    @State private var transportType: TransportType = .stdio
    @State private var stdioCommand = "/usr/local/bin/npx"
    @State private var stdioArgs = "-y @modelcontextprotocol/server-filesystem /Users"
    @State private var httpURL = ""
    @State private var enabled = true
    
    enum TransportType: String, CaseIterable, Identifiable {
        case stdio = "Stdio (Local)"
        case http = "HTTP (Remote)"
        var id: String { rawValue }
    }
    
    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Text("Add MCP Server")
                .font(AppTheme.Typography.title2)
            
            Form {
                TextField("Server Name", text: $name)
                
                Picker("Transport", selection: $transportType) {
                    ForEach(TransportType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                
                if transportType == .stdio {
                    TextField("Command", text: $stdioCommand)
                    TextField("Arguments (space-separated)", text: $stdioArgs)
                        .help("Example: -y @modelcontextprotocol/server-filesystem /Users")
                } else {
                    TextField("Server URL", text: $httpURL)
                        .help("Example: http://localhost:3000/mcp")
                }
                
                Toggle("Enable after adding", isOn: $enabled)
            }
            .padding()
            
            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Button("Add") {
                    let transport: MCPTransport
                    if transportType == .stdio {
                        let args = stdioArgs.split(separator: " ").map(String.init)
                        transport = .stdio(command: stdioCommand, args: args, env: nil)
                    } else {
                        transport = .http(url: httpURL, headers: nil)
                    }
                    let config = MCPServerConfig(name: name, transport: transport, enabled: enabled)
                    Task {
                        await mcpService.addServer(config)
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || (transportType == .http && httpURL.isEmpty))
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 500)
    }
}

struct EditMCPServerView: View {
    let mcpService: MCPService
    let config: MCPServerConfig
    let onDismiss: () -> Void
    
    @State private var name: String
    @State private var stdioCommand: String
    @State private var stdioArgs: String
    @State private var httpURL: String
    @State private var enabled: Bool
    
    init(mcpService: MCPService, config: MCPServerConfig, onDismiss: @escaping () -> Void) {
        self.mcpService = mcpService
        self.config = config
        self.onDismiss = onDismiss
        
        _name = State(initialValue: config.name)
        _enabled = State(initialValue: config.enabled)
        
        switch config.transport {
        case .stdio(let command, let args, _):
            _stdioCommand = State(initialValue: command)
            _stdioArgs = State(initialValue: args.joined(separator: " "))
            _httpURL = State(initialValue: "")
        case .http(let url, _):
            _stdioCommand = State(initialValue: "")
            _stdioArgs = State(initialValue: "")
            _httpURL = State(initialValue: url)
        }
    }
    
    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Text("Edit MCP Server")
                .font(AppTheme.Typography.title2)
            
            Form {
                TextField("Server Name", text: $name)
                
                if case .stdio = config.transport {
                    TextField("Command", text: $stdioCommand)
                    TextField("Arguments (space-separated)", text: $stdioArgs)
                } else {
                    TextField("Server URL", text: $httpURL)
                }
                
                Toggle("Enabled", isOn: $enabled)
            }
            .padding()
            
            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Button("Save") {
                    let transport: MCPTransport
                    if case .stdio = config.transport {
                        let args = stdioArgs.split(separator: " ").map(String.init)
                        transport = .stdio(command: stdioCommand, args: args, env: nil)
                    } else {
                        transport = .http(url: httpURL, headers: nil)
                    }
                    let newConfig = MCPServerConfig(name: name, transport: transport, enabled: enabled)
                    Task {
                        await mcpService.removeServer(config)
                        await mcpService.addServer(newConfig)
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 500)
    }
}