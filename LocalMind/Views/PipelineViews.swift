//
//  PipelineViews.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import SwiftUI

// MARK: - Editor

/// Create/edit sheet for an agent pipeline — an ordered chain of agents,
/// each transforming the previous step's output.
struct PipelineEditorView: View {
    let dataStore: DataStore
    let onSave: (AgentPipeline) -> Void
    let onCancel: () -> Void

    private let existing: AgentPipeline?

    @State private var name: String
    @State private var emoji: String
    @State private var steps: [PipelineStep]

    init(
        pipeline: AgentPipeline?,
        dataStore: DataStore,
        onSave: @escaping (AgentPipeline) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.existing = pipeline
        self.dataStore = dataStore
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: pipeline?.name ?? "")
        _emoji = State(initialValue: pipeline?.emoji ?? "🔗")
        // One starter step, pre-filled so a new user sees what an instruction
        // looks like instead of a blank form.
        _steps = State(initialValue: pipeline?.steps ?? [PipelineStep(instruction: "")])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(existing == nil ? "New Pipeline" : "Edit Pipeline")
                    .font(AppTheme.Typography.title2)
                Text("Each step receives the previous step's output — e.g. Writer drafts → Critic reviews → Writer revises.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("Emoji", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                TextField("Name (e.g. Draft & Review)", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            ScrollView {
                VStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(index: index, step: step)
                    }
                }
            }
            .frame(maxHeight: 300)

            Button {
                steps.append(PipelineStep())
            } label: {
                Label("Add step", systemImage: "plus")
            }
            .controlSize(.small)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || steps.isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 520)
    }

    private func stepRow(index: Int, step: PipelineStep) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Text("Step \(index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accentPrimary)

                Picker("", selection: Binding(
                    get: { steps[index].agentID },
                    set: { steps[index].agentID = $0 }
                )) {
                    Text("Default assistant").tag(UUID?.none)
                    ForEach(dataStore.agents) { agent in
                        Text("\(agent.emoji) \(agent.name)").tag(Optional(agent.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)

                Spacer()

                Button {
                    steps.removeAll { $0.id == step.id }
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(steps.count <= 1)
            }

            TextField(
                index == 0 ? "Instruction (e.g. Draft an answer to the request)" : "Instruction (e.g. Critique the draft above)",
                text: Binding(
                    get: { steps[index].instruction },
                    set: { steps[index].instruction = $0 }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .lineLimit(1...3)
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppTheme.Colors.backgroundSecondary.opacity(0.5))
        )
    }

    private func save() {
        var pipeline = existing ?? AgentPipeline(name: name)
        pipeline.name = name.trimmingCharacters(in: .whitespaces)
        pipeline.emoji = emoji.isEmpty ? "🔗" : String(emoji.prefix(2))
        pipeline.steps = steps
        onSave(pipeline)
    }
}

// MARK: - Runner

/// Runs a pipeline: one prompt in, each step streaming its output in order,
/// with the final result saveable as a conversation.
struct PipelineRunnerView: View {
    let pipeline: AgentPipeline
    let aiManager: AIServiceManager
    let dataStore: DataStore
    let onClose: () -> Void

    @State private var input = ""
    @State private var stepOutputs: [String] = []
    @State private var currentStep = -1
    @State private var isRunning = false
    @State private var runError: String?
    @State private var runTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    private var hasRun: Bool { !stepOutputs.isEmpty }
    private var finishedSuccessfully: Bool {
        hasRun && !isRunning && runError == nil && !(stepOutputs.last ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pipeline.emoji) \(pipeline.name)")
                        .font(AppTheme.Typography.headline)
                    Text(stepsSummary)
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") {
                    runTask?.cancel()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("What should the pipeline work on?", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit { if canRun { run() } }
                if isRunning {
                    Button {
                        runTask?.cancel()
                        isRunning = false
                        currentStep = -1
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        run()
                    } label: {
                        Label(hasRun ? "Run again" : "Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if !hasRun {
                        Text("Each step's output feeds the next. Results appear here as they stream.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, AppTheme.Spacing.xl)
                    } else {
                        ForEach(Array(pipeline.steps.enumerated()), id: \.element.id) { index, step in
                            stepOutputView(index: index, step: step)
                        }
                    }
                    if let runError {
                        Label(runError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.accentOrange)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if finishedSuccessfully {
                HStack {
                    Spacer()
                    Button {
                        copyFinalOutput()
                    } label: {
                        Label("Copy final output", systemImage: "doc.on.doc")
                    }
                    Button {
                        saveAsChat()
                    } label: {
                        Label("Open as chat", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 620)
        .onAppear { inputFocused = true }
        .onDisappear { runTask?.cancel() }
    }

    private var stepsSummary: String {
        pipeline.steps.enumerated().map { index, step in
            let name = dataStore.agent(withID: step.agentID)?.name ?? "Assistant"
            return "\(index + 1). \(name)"
        }.joined(separator: " → ")
    }

    private var canRun: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pipeline.steps.isEmpty
            && !isRunning
            && aiManager.currentService != nil
    }

    @ViewBuilder
    private func stepOutputView(index: Int, step: PipelineStep) -> some View {
        let agent = dataStore.agent(withID: step.agentID)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(AppTheme.Colors.accentPrimary.opacity(0.15)))
                    .foregroundStyle(AppTheme.Colors.accentPrimary)
                Text("\(agent?.emoji ?? "🤖") \(agent?.name ?? "Assistant")")
                    .font(.system(size: 12, weight: .semibold))
                if !step.instruction.isEmpty {
                    Text("— \(step.instruction)")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if currentStep == index {
                    ProgressView().controlSize(.mini)
                }
            }
            if index < stepOutputs.count, !stepOutputs[index].isEmpty {
                MessageMarkdownView(text: stepOutputs[index])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AppTheme.Colors.backgroundSecondary.opacity(0.5))
                    )
            } else if currentStep == index {
                Text("Working…")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func run() {
        runTask?.cancel()
        runError = nil
        stepOutputs = Array(repeating: "", count: pipeline.steps.count)
        isRunning = true
        let request = input.trimmingCharacters(in: .whitespacesAndNewlines)

        runTask = Task {
            var previousOutput = request
            for (index, step) in pipeline.steps.enumerated() {
                if Task.isCancelled { break }
                currentStep = index

                let agent = dataStore.agent(withID: step.agentID)
                guard let service = await aiManager.service(matching: agent?.backend) else {
                    runError = AIServiceError.noBackendAvailable.localizedDescription
                    break
                }

                let systemPrompt = agent?.systemPrompt
                    ?? "You are a capable assistant executing one stage of a multi-step workflow."
                let instruction = step.instruction.isEmpty
                    ? (index == 0 ? "Complete the request." : "Improve on the previous step's output.")
                    : step.instruction
                let userContent: String
                if index == 0 {
                    userContent = "\(request)\n\nYour task: \(instruction)"
                } else {
                    userContent = """
                    Original request:
                    \(request)

                    Output from the previous step:
                    \(previousOutput)

                    Your task: \(instruction)
                    """
                }

                let model: String?
                if let pinned = agent?.modelID {
                    if let backend = agent?.backend, backend != aiManager.currentBackend {
                        model = pinned
                    } else {
                        model = aiManager.allAvailableModelIDs.contains(pinned) ? pinned : nil
                    }
                } else {
                    model = nil
                }
                let parameters: AIParameters = {
                    var params = aiManager.aiParameters
                    if let temperature = agent?.temperature {
                        params.temperature = temperature
                    }
                    return params
                }()

                do {
                    for try await chunk in service.streamChat(
                        messages: [ChatMessage(role: .user, content: userContent)],
                        systemPrompt: systemPrompt,
                        modelOverride: model,
                        parameters: parameters,
                        tools: nil
                    ) {
                        if Task.isCancelled { break }
                        if case .text(let text) = chunk {
                            stepOutputs[index] += text
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        runError = error.localizedDescription
                    }
                    break
                }

                stepOutputs[index] = stepOutputs[index].strippingThinkBlocks
                if stepOutputs[index].isEmpty {
                    runError = "Step \(index + 1) produced no output."
                    break
                }
                previousOutput = stepOutputs[index]
            }
            currentStep = -1
            isRunning = false
        }
    }

    private func copyFinalOutput() {
        guard let final = stepOutputs.last, !final.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(final, forType: .string)
    }

    /// Saves the whole run as a conversation — the request, then every step's
    /// output as an attributed assistant message — and opens it.
    private func saveAsChat() {
        let request = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var messages = [ChatMessage(role: .user, content: request)]
        for (index, step) in pipeline.steps.enumerated() where index < stepOutputs.count && !stepOutputs[index].isEmpty {
            let agent = dataStore.agent(withID: step.agentID)
            var message = ChatMessage(role: .assistant, content: stepOutputs[index])
            message.agentName = "\(agent?.name ?? "Assistant") (step \(index + 1))"
            message.agentEmoji = agent?.emoji
            messages.append(message)
        }
        var conversation = Conversation(
            title: "\(pipeline.emoji) " + String(request.prefix(44)) + (request.count > 44 ? "..." : ""),
            messages: messages,
            toolType: .chat,
            emoji: pipeline.emoji
        )
        conversation.updatedAt = Date()
        dataStore.saveConversation(conversation)
        NotificationCenter.default.post(name: .openConversation, object: conversation.id)
        onClose()
    }
}
