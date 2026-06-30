//
//  MCPSettingsView.swift
//  LocalMind
//

import SwiftUI

struct MCPSettingsView: View {
    let mcpService: MCPService

    @State private var showingCatalog = false
    @State private var editingConfig: MCPServerConfig?
    @State private var showingCustomServer = false
    @State private var logsServerName: String?
    @State private var toolsServerName: String?
    @State private var showingAuditLog = false
    @AppStorage("mcpRequireApproval") private var requireApproval = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                header

                approvalControls

                if mcpService.allConfigs.isEmpty {
                    emptyState
                } else {
                    installedServers
                }

                Divider().padding(.vertical, AppTheme.Spacing.sm)

                Text("BROWSE CATALOG")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .tracking(1.2)

                catalog
            }
            .padding(AppTheme.Spacing.xl)
        }
        .sheet(item: $editingConfig) { config in
            EditMCPServerView(mcpService: mcpService, config: config) {
                editingConfig = nil
            }
        }
        .sheet(isPresented: $showingCustomServer) {
            AddCustomServerView(mcpService: mcpService) {
                showingCustomServer = false
            }
        }
        .sheet(item: Binding(
            get: { logsServerName.map(MCPLogIdentifier.init) },
            set: { logsServerName = $0?.name }
        )) { ident in
            MCPLogSheet(mcpService: mcpService, serverName: ident.name) {
                logsServerName = nil
            }
        }
        .sheet(item: Binding(
            get: { toolsServerName.map(MCPLogIdentifier.init) },
            set: { toolsServerName = $0?.name }
        )) { ident in
            MCPToolsSheet(mcpService: mcpService, serverName: ident.name) {
                toolsServerName = nil
            }
        }
        .sheet(isPresented: $showingAuditLog) {
            MCPAuditLogView(mcpService: mcpService) { showingAuditLog = false }
        }
    }

    /// Tool-call safety: the approval switch plus an entry point to the
    /// session's tool-call activity log.
    private var approvalControls: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.Colors.accentPrimary)
            Toggle(isOn: $requireApproval) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask before running tools")
                        .font(AppTheme.Typography.body)
                    Text("Approve each tool call the AI tries to make on your machine.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Spacer()
            Button {
                showingAuditLog = true
            } label: {
                Label("Activity log", systemImage: "list.bullet.rectangle")
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Colors.backgroundSecondary)
        )
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP Servers")
                    .font(AppTheme.Typography.title)
                Text("Give your AI access to tools — files, web search, your notes, anything. Install with one click.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingCustomServer = true
            } label: {
                Label("Custom…", systemImage: "plus")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No servers installed yet.")
                .font(AppTheme.Typography.body)
            Text("Browse the catalog below and click Install on the ones you want.")
                .font(AppTheme.Typography.captionSecondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(AppTheme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Colors.backgroundSecondary)
        )
    }

    private var installedServers: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("INSTALLED")
                .font(AppTheme.Typography.captionSecondary)
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .tracking(1.2)

            VStack(spacing: 6) {
                ForEach(mcpService.allConfigs) { config in
                    MCPServerRowView(
                        config: config,
                        state: mcpService.connectionStates[config.name] ?? .disconnected,
                        toolCount: mcpService.toolCount(for: config.name),
                        onToggle: { await mcpService.toggleServer(config) },
                        onReconnect: { await mcpService.reconnect(config) },
                        onEdit: { editingConfig = config },
                        onDelete: { await mcpService.removeServer(config) },
                        onShowLogs: { logsServerName = config.name },
                        onShowTools: { toolsServerName = config.name }
                    )
                }
            }
        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(MCPCatalogEntry.Category.allCases, id: \.self) { category in
                let entries = MCPCatalog.entries(in: category)
                if !entries.isEmpty {
                    Text(category.rawValue)
                        .font(AppTheme.Typography.headline)
                        .padding(.top, AppTheme.Spacing.sm)
                    VStack(spacing: 6) {
                        ForEach(entries) { entry in
                            CatalogEntryRow(
                                entry: entry,
                                isInstalled: mcpService.allConfigs.contains(where: { $0.name == entry.name }),
                                onInstall: {
                                    Task { await mcpService.addServer(entry.template) }
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Catalog Row

struct CatalogEntryRow: View {
    let entry: MCPCatalogEntry
    let isInstalled: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: entry.iconSystemName)
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.Colors.accentPrimary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppTheme.Colors.backgroundTertiary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(AppTheme.Typography.body)
                    .fontWeight(.medium)
                Text(entry.description)
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let hint = entry.setupHint {
                    Label(hint, systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }

            Spacer()

            if isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Install", action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Colors.backgroundSecondary.opacity(0.5))
        )
    }
}

// MARK: - Installed Server Row

struct MCPServerRowView: View {
    let config: MCPServerConfig
    let state: MCPConnectionState
    let toolCount: Int
    let onToggle: () async -> Void
    let onReconnect: () async -> Void
    let onEdit: () -> Void
    let onDelete: () async -> Void
    let onShowLogs: () -> Void
    let onShowTools: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(config.name)
                        .font(AppTheme.Typography.body)
                        .fontWeight(.medium)
                    ConnectionStatusBadge(state: state)
                    if case .connected = state, toolCount > 0 {
                        Text("\(toolCount) tool\(toolCount == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(AppTheme.Colors.backgroundTertiary)
                            )
                    }
                }
                Text(transportDescription)
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { config.enabled },
                set: { _ in Task { await onToggle() } }
            ))
            .labelsHidden()

            Menu {
                if case .failed = state {
                    Button {
                        Task { await onReconnect() }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    onShowLogs()
                } label: {
                    Label("Show Logs", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    onShowTools()
                } label: {
                    Label("Tools…", systemImage: "wrench.and.screwdriver")
                }
                Button("Edit", action: onEdit)
                Button("Delete", role: .destructive) {
                    Task { await onDelete() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Colors.backgroundSecondary)
        )
    }

    private var transportDescription: String {
        switch config.transport {
        case .stdio(let command, let args, _):
            return "\(command) \(args.joined(separator: " "))"
        case .http(let url, _):
            return url
        }
    }
}

struct ConnectionStatusBadge: View {
    let state: MCPConnectionState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
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
        case .connecting: return "Connecting"
        case .disconnected: return "Off"
        case .failed: return "Error"
        }
    }
}

// MARK: - Custom Server Sheet

struct AddCustomServerView: View {
    let mcpService: MCPService
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var command = "npx"
    @State private var args = "-y @modelcontextprotocol/server-filesystem ~/Documents"
    @State private var envVars = ""
    @State private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("Add Custom MCP Server")
                .font(AppTheme.Typography.title2)

            Form {
                TextField("Name", text: $name)
                    .help("Friendly label shown in the sidebar")
                TextField("Command", text: $command)
                    .help("npx, node, python, or any absolute path")
                TextField("Arguments", text: $args)
                    .help("Space-separated arguments to pass to the command")
                TextField("Environment (KEY=value, one per line)", text: $envVars, axis: .vertical)
                    .lineLimit(3...5)
                Toggle("Enable after adding", isOn: $enabled)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    let argsList = args.split(separator: " ").map(String.init)
                    let envDict = parseEnv(envVars)
                    let transport: MCPTransport = .stdio(
                        command: command,
                        args: argsList,
                        env: envDict.isEmpty ? nil : envDict
                    )
                    let config = MCPServerConfig(name: name, transport: transport, enabled: enabled)
                    Task {
                        await mcpService.addServer(config)
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || command.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 520)
    }

    private func parseEnv(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}

// MARK: - Edit Sheet

struct EditMCPServerView: View {
    let mcpService: MCPService
    let config: MCPServerConfig
    let onDismiss: () -> Void

    @State private var command: String
    @State private var args: String
    @State private var envVars: String

    init(mcpService: MCPService, config: MCPServerConfig, onDismiss: @escaping () -> Void) {
        self.mcpService = mcpService
        self.config = config
        self.onDismiss = onDismiss

        switch config.transport {
        case .stdio(let cmd, let argList, let env):
            _command = State(initialValue: cmd)
            _args = State(initialValue: argList.joined(separator: " "))
            _envVars = State(initialValue: (env ?? [:])
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "\n"))
        case .http(let url, _):
            _command = State(initialValue: url)
            _args = State(initialValue: "")
            _envVars = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("Edit \(config.name)")
                .font(AppTheme.Typography.title2)

            Form {
                TextField("Command", text: $command)
                TextField("Arguments", text: $args)
                TextField("Environment (KEY=value)", text: $envVars, axis: .vertical)
                    .lineLimit(3...8)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let argsList = args.split(separator: " ").map(String.init)
                    let envDict = parseEnv(envVars)
                    let transport: MCPTransport = .stdio(
                        command: command,
                        args: argsList,
                        env: envDict.isEmpty ? nil : envDict
                    )
                    let newConfig = MCPServerConfig(name: config.name, transport: transport, enabled: config.enabled)
                    Task {
                        await mcpService.addServer(newConfig)
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 520)
    }

    private func parseEnv(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}

// MARK: - Log Sheet

/// `sheet(item:)` needs an Identifiable wrapper because the bound value
/// (server name `String`) isn't itself Identifiable.
struct MCPLogIdentifier: Identifiable {
    let name: String
    var id: String { name }
}

struct MCPLogSheet: View {
    let mcpService: MCPService
    let serverName: String
    let onDismiss: () -> Void

    @State private var lines: [MCPLogLine] = []
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("\(serverName) logs")
                    .font(AppTheme.Typography.title2)
                Spacer()
                Button("Clear") {
                    Task {
                        await mcpService.clearLogs(for: serverName)
                        lines = []
                    }
                }
                .disabled(lines.isEmpty)
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }

            if lines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No log output yet.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(timeString(line.timestamp))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 60, alignment: .leading)
                                    Text(line.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(line.source == .transport ? .orange : .primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(line.id)
                            }
                        }
                        .padding(8)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AppTheme.Colors.backgroundSecondary)
                    )
                    .onChange(of: lines.count) { _, _ in
                        if let last = lines.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 680, height: 480)
        .task { await reload() }
        // Cheap polling — the ring buffer is on the actor; an actor signal
        // would be cleaner but this sheet is transient and 1Hz refresh is
        // invisible to the user.
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in await reload() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func reload() async {
        lines = await mcpService.recentLogs(for: serverName)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Tools Sheet

struct MCPToolsSheet: View {
    let mcpService: MCPService
    let serverName: String
    let onDismiss: () -> Void

    var body: some View {
        let tools = mcpService.allToolsByServer[serverName] ?? []
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(serverName) tools")
                        .font(AppTheme.Typography.title2)
                    Text("Disabled tools are hidden from the model entirely.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }

            if tools.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No tools available — the server isn't connected.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(tools) { tool in
                            let enabled = mcpService.isToolEnabled(server: serverName, tool: tool.name)
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(enabled ? .primary : .secondary)
                                    if let desc = tool.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(AppTheme.Typography.captionSecondary)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { enabled },
                                    set: { newValue in
                                        Task {
                                            await mcpService.setToolEnabled(newValue, server: serverName, tool: tool.name)
                                        }
                                    }
                                ))
                                .labelsHidden()
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(AppTheme.Colors.backgroundSecondary)
                            )
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 580, height: 520)
    }
}

// MARK: - Tool-call Activity Log

/// Read-only audit trail of every tool call the AI attempted this session.
struct MCPAuditLogView: View {
    let mcpService: MCPService
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool Activity")
                        .font(AppTheme.Typography.headline)
                    Text("Every tool call the AI has made this session.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { mcpService.clearAuditLog() }
                    .disabled(mcpService.auditLog.isEmpty)
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            if mcpService.auditLog.isEmpty {
                VStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "checklist")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No tool calls yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(mcpService.auditLog.reversed()) { record in
                            auditRow(record)
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 560, height: 480)
    }

    private func auditRow(_ record: MCPToolCallRecord) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: record.status.systemImage)
                .foregroundStyle(color(for: record.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(record.toolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("· \(record.status.rawValue)")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(color(for: record.status))
                    Spacer()
                    Text(record.timestamp.formatted(date: .omitted, time: .standard))
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.tertiary)
                }
                Text(record.detail)
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppTheme.Colors.backgroundSecondary.opacity(0.5))
        )
    }

    private func color(for status: MCPToolCallRecord.Status) -> Color {
        switch status {
        case .allowed: return .green
        case .denied:  return .orange
        case .error:   return .red
        }
    }
}
