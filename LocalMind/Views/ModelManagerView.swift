//
//  ModelManagerView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import SwiftUI

/// In-app model management for the active backend, embedded in Settings →
/// Providers. Ollama gets the full treatment (browse, pull with progress,
/// delete) because it exposes a management API; OpenAI-compatible servers
/// show their live catalogue with a pointer to the server's own manager;
/// Apple Intelligence is informational.
struct ModelManagerView: View {
    let aiManager: AIServiceManager

    @State private var pullName = ""
    @State private var isPulling = false
    @State private var pullStatus = ""
    @State private var pullFraction: Double?
    @State private var pullError: String?
    @State private var pullTask: Task<Void, Never>?
    @State private var modelPendingDeletion: OllamaModel?

    /// Common starter models, so pulling doesn't require knowing exact tags.
    private static let suggestedModels: [(name: String, blurb: String)] = [
        ("llama3.2:3b", "Fast & small — great on 8 GB Macs"),
        ("qwen3:8b", "Balanced default for chat"),
        ("qwen2.5-coder:7b", "Tuned for code"),
        ("qwen3:14b", "Stronger reasoning, needs 16 GB+"),
        ("llava:7b", "Vision — required for image analysis"),
        ("nomic-embed-text", "Embeddings for the knowledge base")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            switch aiManager.currentBackend {
            case .ollama:
                ollamaManager
            case .openAICompatible:
                openAIManager
            case .appleFoundationModels:
                Text("Apple Intelligence runs a single on-device foundation model managed by macOS — there's nothing to install or remove.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .none:
                Text("Connect a backend to manage its models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { pullTask?.cancel() }
    }

    // MARK: - Ollama

    private var ollamaManager: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            // Installed models
            if aiManager.availableModels.isEmpty {
                Text("No models installed yet — pull one below to get started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(aiManager.availableModels) { model in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Circle()
                            .fill(model.name == aiManager.selectedOllamaModel
                                  ? AppTheme.Colors.statusOnline : Color.clear)
                            .frame(width: 6, height: 6)
                        Text(model.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(model.formattedSize)
                            .font(AppTheme.Typography.captionSecondary)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.name == aiManager.selectedOllamaModel {
                            Text("active")
                                .font(AppTheme.Typography.captionSecondary)
                                .foregroundStyle(AppTheme.Colors.statusOnline)
                        }
                        Button {
                            modelPendingDeletion = model
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isPulling)
                        .help("Delete this model from disk")
                    }
                }
            }

            Divider()

            // Pull a new model
            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("Model to pull, e.g. qwen3:8b", text: $pullName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(isPulling)
                    .onSubmit { startPull() }

                Menu {
                    ForEach(Self.suggestedModels, id: \.name) { suggestion in
                        Button {
                            pullName = suggestion.name
                        } label: {
                            Text("\(suggestion.name) — \(suggestion.blurb)")
                        }
                    }
                } label: {
                    Image(systemName: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Suggested models")
                .disabled(isPulling)

                if isPulling {
                    Button("Cancel") { cancelPull() }
                        .controlSize(.small)
                } else {
                    Button("Pull") { startPull() }
                        .controlSize(.small)
                        .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if isPulling {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = pullFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(pullStatus.isEmpty ? "Starting download…" : pullStatus)
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
            }

            if let pullError {
                Label(pullError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.accentOrange)
            }
        }
        .confirmationDialog(
            "Delete \(modelPendingDeletion?.name ?? "model")?",
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            presenting: modelPendingDeletion
        ) { model in
            Button("Delete \(model.name) (\(model.formattedSize))", role: .destructive) {
                Task {
                    do {
                        try await aiManager.deleteOllamaModel(model.name)
                    } catch {
                        pullError = error.localizedDescription
                    }
                }
                modelPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { modelPendingDeletion = nil }
        } message: { model in
            Text("Frees \(model.formattedSize) of disk space. You can pull it again anytime.")
        }
    }

    private func startPull() {
        let name = pullName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isPulling else { return }
        isPulling = true
        pullError = nil
        pullStatus = ""
        pullFraction = nil

        pullTask = Task {
            do {
                for try await progress in aiManager.pullOllamaModel(name) {
                    if Task.isCancelled { break }
                    pullStatus = progress.status
                    if let fraction = progress.fraction {
                        pullFraction = fraction
                        if let total = progress.total, let done = progress.completed {
                            let gb = { (bytes: Int64) in String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
                            pullStatus = "\(progress.status) — \(gb(done)) of \(gb(total))"
                        }
                    }
                }
                if !Task.isCancelled {
                    pullName = ""
                    await aiManager.refreshModelList()
                }
            } catch {
                if !Task.isCancelled {
                    pullError = error.localizedDescription
                }
            }
            isPulling = false
        }
    }

    private func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        isPulling = false
        pullStatus = ""
    }

    // MARK: - OpenAI-compatible

    private var openAIManager: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if aiManager.availableOpenAIModels.isEmpty {
                Text("The server reports no loaded models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(aiManager.availableOpenAIModels) { model in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Circle()
                            .fill(model.id == aiManager.selectedOpenAIModel
                                  ? AppTheme.Colors.statusOnline : Color.clear)
                            .frame(width: 6, height: 6)
                        Text(model.id)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if model.id == aiManager.selectedOpenAIModel {
                            Text("active")
                                .font(AppTheme.Typography.captionSecondary)
                                .foregroundStyle(AppTheme.Colors.statusOnline)
                        }
                    }
                }
            }
            HStack {
                Text("Downloading and removing models happens in \(aiManager.openAIServerName) itself — the OpenAI API doesn't manage model files.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Refresh") {
                    Task { await aiManager.refreshModelList() }
                }
                .controlSize(.small)
            }
        }
    }
}
