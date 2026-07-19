//
//  AgentSettingsView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import SwiftUI
import UniformTypeIdentifiers

/// Settings tab for managing agents: create, edit, duplicate, delete,
/// import, and export the personas that conversations and the Agent Team
/// panel run.
struct AgentSettingsView: View {
    let dataStore: DataStore
    let aiManager: AIServiceManager

    @State private var editingAgent: Agent?
    @State private var isCreating = false
    @State private var importStatus = ""
    @State private var editingPipeline: AgentPipeline?
    @State private var isCreatingPipeline = false
    @State private var runningPipeline: AgentPipeline?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents")
                        .font(AppTheme.Typography.title2)
                    Text("Personas with their own instructions, backend, model, and creativity. Assign one to a chat, or run several at once as a team.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Menu {
                    Button {
                        importAgents()
                    } label: {
                        Label("Import Agents…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        exportAgents()
                    } label: {
                        Label("Export All Agents…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(dataStore.agents.isEmpty)
                    Divider()
                    Button {
                        importPipelines()
                    } label: {
                        Label("Import Pipelines…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        exportPipelines()
                    } label: {
                        Label("Export All Pipelines…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(dataStore.pipelines.isEmpty)
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Share agents and pipelines as JSON files")

                Button {
                    isCreating = true
                } label: {
                    Label("New Agent", systemImage: "plus")
                }
            }

            if !importStatus.isEmpty {
                Text(importStatus)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.accentPrimary)
            }

            if dataStore.agents.isEmpty {
                VStack(spacing: AppTheme.Spacing.md) {
                    Text("No agents yet.")
                        .foregroundStyle(.secondary)
                    Button("Add the starter agents") {
                        for template in Agent.starterTemplates() {
                            dataStore.saveAgent(template)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.xl)
            } else {
                List {
                    ForEach(dataStore.agents) { agent in
                        agentRow(agent)
                    }
                }
                .listStyle(.bordered)
            }

            pipelinesSection
        }
        .padding(AppTheme.Spacing.xl)
        .sheet(isPresented: $isCreating) {
            AgentEditorView(
                agent: nil,
                aiManager: aiManager,
                mcpToolNames: aiManager.getAvailableTools().map(\.name),
                onSave: { agent in
                    dataStore.saveAgent(agent)
                    isCreating = false
                },
                onCancel: { isCreating = false }
            )
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditorView(
                agent: agent,
                aiManager: aiManager,
                mcpToolNames: aiManager.getAvailableTools().map(\.name),
                onSave: { updated in
                    dataStore.saveAgent(updated)
                    editingAgent = nil
                },
                onCancel: { editingAgent = nil }
            )
        }
        .sheet(isPresented: $isCreatingPipeline) {
            PipelineEditorView(
                pipeline: nil,
                dataStore: dataStore,
                onSave: { pipeline in
                    dataStore.savePipeline(pipeline)
                    isCreatingPipeline = false
                },
                onCancel: { isCreatingPipeline = false }
            )
        }
        .sheet(item: $editingPipeline) { pipeline in
            PipelineEditorView(
                pipeline: pipeline,
                dataStore: dataStore,
                onSave: { updated in
                    dataStore.savePipeline(updated)
                    editingPipeline = nil
                },
                onCancel: { editingPipeline = nil }
            )
        }
        .sheet(item: $runningPipeline) { pipeline in
            PipelineRunnerView(
                pipeline: pipeline,
                aiManager: aiManager,
                dataStore: dataStore,
                onClose: { runningPipeline = nil }
            )
        }
    }

    // MARK: - Pipelines

    private var pipelinesSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pipelines")
                        .font(AppTheme.Typography.headline)
                    Text("Chain agents into reusable workflows — each step transforms the previous step's output.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isCreatingPipeline = true
                } label: {
                    Label("New Pipeline", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if dataStore.pipelines.isEmpty {
                Text("No pipelines yet — try Writer drafts → Critic reviews → Writer revises.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(dataStore.pipelines) { pipeline in
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text(pipeline.emoji)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pipeline.name)
                                .font(.system(size: 12, weight: .semibold))
                            Text(pipelineSummary(pipeline))
                                .font(AppTheme.Typography.captionSecondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Run") { runningPipeline = pipeline }
                            .controlSize(.small)
                        Button("Edit") { editingPipeline = pipeline }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Colors.accentPrimary)
                        Button("Delete", role: .destructive) { dataStore.deletePipeline(pipeline) }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Colors.accentRed)
                    }
                    .padding(AppTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AppTheme.Colors.backgroundSecondary.opacity(0.5))
                    )
                }
            }
        }
    }

    private func pipelineSummary(_ pipeline: AgentPipeline) -> String {
        pipeline.steps.map { step in
            dataStore.agent(withID: step.agentID)?.name ?? "Assistant"
        }.joined(separator: " → ")
    }

    private func agentRow(_ agent: Agent) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(agent.emoji)
                .font(.system(size: 20))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .semibold))
                    // Where this agent runs, resolved against the live setup —
                    // answers "which agent uses which model" at a glance.
                    Text(aiManager.resolvedModelDescription(for: agent))
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background { Capsule().fill(AppTheme.Colors.backgroundTertiary.opacity(0.6)) }
                    if agent.useKnowledgeBase {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                            .help("Uses the knowledge base")
                    }
                    if !agent.allowTools {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                            .opacity(0.5)
                            .help("MCP tools disabled")
                    } else if let allowed = agent.allowedToolIDs {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.Colors.accentPrimary)
                            .help("Limited to \(allowed.count) tool\(allowed.count == 1 ? "" : "s"): \(allowed.joined(separator: ", "))")
                    }
                }
                Text(agent.tagline.isEmpty ? String(agent.systemPrompt.prefix(80)) : agent.tagline)
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Edit") { editingAgent = agent }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.accentPrimary)

            Button {
                let duplicated = Agent(
                    name: agent.name + " copy",
                    emoji: agent.emoji,
                    tagline: agent.tagline,
                    systemPrompt: agent.systemPrompt,
                    backend: agent.backend,
                    modelID: agent.modelID,
                    temperature: agent.temperature,
                    allowTools: agent.allowTools,
                    allowedToolIDs: agent.allowedToolIDs,
                    useKnowledgeBase: agent.useKnowledgeBase,
                    knowledgeCollections: agent.knowledgeCollections
                )
                dataStore.saveAgent(duplicated)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Duplicate")

            Button("Delete", role: .destructive) {
                dataStore.deleteAgent(agent)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Colors.accentRed)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Import / Export

    private func exportAgents() {
        guard let data = dataStore.exportAgentsData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LocalMind-Agents.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func importAgents() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            let count = dataStore.importAgents(from: data)
            importStatus = count > 0
                ? "Imported \(count) agent\(count == 1 ? "" : "s")."
                : "That file doesn't contain any agents."
            Task {
                try? await Task.sleep(for: .seconds(4))
                importStatus = ""
            }
        }
    }

    private func exportPipelines() {
        guard let data = dataStore.exportPipelinesData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LocalMind-Pipelines.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func importPipelines() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            let count = dataStore.importPipelines(from: data)
            importStatus = count > 0
                ? "Imported \(count) pipeline\(count == 1 ? "" : "s")."
                : "That file doesn't contain any pipelines."
            Task {
                try? await Task.sleep(for: .seconds(4))
                importStatus = ""
            }
        }
    }
}

// MARK: - Editor

/// Create/edit sheet for a single agent.
struct AgentEditorView: View {
    let aiManager: AIServiceManager
    /// Names of the MCP tools currently connected (for the allowlist).
    let mcpToolNames: [String]
    let onSave: (Agent) -> Void
    let onCancel: () -> Void

    private let existing: Agent?

    @State private var name: String
    @State private var emoji: String
    @State private var tagline: String
    @State private var systemPrompt: String
    /// nil = follow the currently connected backend.
    @State private var backend: AIBackend?
    @State private var modelID: String
    @State private var usesCustomTemperature: Bool
    @State private var temperature: Double
    @State private var allowTools: Bool
    @State private var restrictTools: Bool
    @State private var selectedToolNames: Set<String>
    @State private var useKnowledgeBase: Bool
    @State private var restrictCollections: Bool
    @State private var selectedCollections: Set<String>

    /// Models offered by the picked backend, loaded live when it changes.
    @State private var backendModels: [String] = []
    @State private var backendReachable = true
    @State private var isLoadingModels = false

    init(
        agent: Agent?,
        aiManager: AIServiceManager,
        mcpToolNames: [String],
        onSave: @escaping (Agent) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.existing = agent
        self.aiManager = aiManager
        self.mcpToolNames = mcpToolNames
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: agent?.name ?? "")
        _emoji = State(initialValue: agent?.emoji ?? "🤖")
        _tagline = State(initialValue: agent?.tagline ?? "")
        _systemPrompt = State(initialValue: agent?.systemPrompt ?? "You are a helpful assistant.")
        _backend = State(initialValue: agent?.backend)
        _modelID = State(initialValue: agent?.modelID ?? "")
        _usesCustomTemperature = State(initialValue: agent?.temperature != nil)
        _temperature = State(initialValue: agent?.temperature ?? aiManager.aiParameters.temperature)
        _allowTools = State(initialValue: agent?.allowTools ?? true)
        _restrictTools = State(initialValue: agent?.allowedToolIDs != nil)
        _selectedToolNames = State(initialValue: Set(agent?.allowedToolIDs ?? []))
        _useKnowledgeBase = State(initialValue: agent?.useKnowledgeBase ?? false)
        _restrictCollections = State(initialValue: agent?.knowledgeCollections != nil)
        _selectedCollections = State(initialValue: Set(agent?.knowledgeCollections ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack {
                Text(existing == nil ? "New Agent" : "Edit Agent")
                    .font(AppTheme.Typography.title2)
                Spacer()
                if existing == nil {
                    Menu {
                        ForEach(Agent.starterTemplates()) { template in
                            Button("\(template.emoji) \(template.name)") {
                                applyTemplate(template)
                            }
                        }
                    } label: {
                        Label("Start from template", systemImage: "sparkles")
                    }
                    .fixedSize()
                }
            }

            ScrollView {
                Form {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        TextField("Emoji", text: $emoji)
                            .frame(width: 60)
                            .help("One emoji used as this agent's face")
                        TextField("Name", text: $name)
                    }

                    TextField("Tagline (shown in pickers)", text: $tagline)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instructions")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 12))
                            .frame(height: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(AppTheme.Colors.divider, lineWidth: 1)
                            )
                    }

                    Picker("Backend", selection: $backend) {
                        Text("Current (\(aiManager.currentBackend == .none ? "auto" : aiManager.currentBackend.rawValue))")
                            .tag(AIBackend?.none)
                        Text("Apple Intelligence").tag(Optional(AIBackend.appleFoundationModels))
                        Text("Ollama").tag(Optional(AIBackend.ollama))
                        Text("OpenAI Compatible").tag(Optional(AIBackend.openAICompatible))
                    }
                    .help("Pin this agent to a backend — a team run can then mix backends in parallel")

                    if !backendReachable {
                        Label("This backend isn't reachable right now — the agent will fall back to the current one until it comes online.", systemImage: "exclamationmark.triangle")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Colors.accentOrange)
                    }

                    Picker("Model", selection: $modelID) {
                        Text(isLoadingModels ? "Loading models…" : "Default (follow global setting)").tag("")
                        ForEach(backendModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                        // Keep a pinned model visible even when its backend is
                        // currently offline, so editing doesn't silently drop it.
                        if !modelID.isEmpty && !backendModels.contains(modelID) {
                            Text("\(modelID) (unavailable)").tag(modelID)
                        }
                    }

                    Toggle("Custom temperature", isOn: $usesCustomTemperature)
                    if usesCustomTemperature {
                        HStack {
                            Slider(value: $temperature, in: 0...1, step: 0.05)
                            Text(String(format: "%.2f", temperature))
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 36)
                        }
                    }

                    Toggle("Allow MCP tools", isOn: $allowTools)
                    if allowTools {
                        Toggle("Limit to specific tools", isOn: $restrictTools)
                            .padding(.leading, AppTheme.Spacing.lg)
                        if restrictTools {
                            if mcpToolNames.isEmpty {
                                Text("No MCP tools are connected right now. Names you've allowed before are kept.")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, AppTheme.Spacing.lg)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(mcpToolNames, id: \.self) { toolName in
                                        Toggle(toolName, isOn: Binding(
                                            get: { selectedToolNames.contains(toolName) },
                                            set: { included in
                                                if included {
                                                    selectedToolNames.insert(toolName)
                                                } else {
                                                    selectedToolNames.remove(toolName)
                                                }
                                            }
                                        ))
                                        .font(AppTheme.Typography.caption)
                                    }
                                }
                                .padding(.leading, AppTheme.Spacing.xl)
                            }
                        }
                    }

                    Toggle("Use knowledge base (chat with your documents)", isOn: $useKnowledgeBase)
                    if useKnowledgeBase {
                        let collections = KnowledgeBaseStore.shared.collections
                        if !collections.isEmpty {
                            Toggle("Limit to specific collections", isOn: $restrictCollections)
                                .padding(.leading, AppTheme.Spacing.lg)
                            if restrictCollections {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(collections, id: \.self) { collection in
                                        Toggle(collection, isOn: Binding(
                                            get: { selectedCollections.contains(collection) },
                                            set: { included in
                                                if included {
                                                    selectedCollections.insert(collection)
                                                } else {
                                                    selectedCollections.remove(collection)
                                                }
                                            }
                                        ))
                                        .font(AppTheme.Typography.caption)
                                    }
                                }
                                .padding(.leading, AppTheme.Spacing.xl)
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 540, height: 620)
        .task(id: backend) {
            await reloadBackendInfo()
        }
    }

    /// Fetches the picked backend's model list and reachability. Runs on
    /// appear and whenever the backend picker changes.
    private func reloadBackendInfo() async {
        isLoadingModels = true
        let target = backend ?? aiManager.currentBackend
        backendModels = await aiManager.modelIDs(for: target)
        if backend == nil {
            backendReachable = true
        } else {
            backendReachable = await aiManager.isBackendAvailable(target)
        }
        isLoadingModels = false
    }

    private func applyTemplate(_ template: Agent) {
        name = template.name
        emoji = template.emoji
        tagline = template.tagline
        systemPrompt = template.systemPrompt
        usesCustomTemperature = template.temperature != nil
        temperature = template.temperature ?? aiManager.aiParameters.temperature
        allowTools = template.allowTools
        useKnowledgeBase = template.useKnowledgeBase
    }

    private func save() {
        var agent = existing ?? Agent(name: name, systemPrompt: systemPrompt)
        agent.name = name.trimmingCharacters(in: .whitespaces)
        agent.emoji = emoji.isEmpty ? "🤖" : String(emoji.prefix(2))
        agent.tagline = tagline.trimmingCharacters(in: .whitespaces)
        agent.systemPrompt = systemPrompt
        agent.backend = backend
        agent.modelID = modelID.isEmpty ? nil : modelID
        agent.temperature = usesCustomTemperature ? temperature : nil
        agent.allowTools = allowTools
        agent.allowedToolIDs = (allowTools && restrictTools) ? Array(selectedToolNames).sorted() : nil
        agent.useKnowledgeBase = useKnowledgeBase
        agent.knowledgeCollections = (useKnowledgeBase && restrictCollections) ? Array(selectedCollections).sorted() : nil
        agent.updatedAt = Date()
        onSave(agent)
    }
}
