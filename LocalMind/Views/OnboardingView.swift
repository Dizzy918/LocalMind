//
//  OnboardingView.swift
//  LocalMind
//
//  First-run experience. The single biggest reason local-AI apps get
//  deleted in the first five minutes is an empty screen with no model and
//  no guidance — this flow walks from "nothing installed" to a working
//  first answer: detect what's available, get Ollama if needed, pull a
//  model sized to this Mac's memory, then show what the app can do.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct OnboardingView: View {
    let aiManager: AIServiceManager
    let onFinish: () -> Void

    private enum Step {
        case welcome
        case backend
        case features
    }

    @State private var step: Step = .welcome

    // Model pull state (Ollama path)
    @State private var isPulling = false
    @State private var pullStatus = ""
    @State private var pullFraction: Double?
    @State private var pullError: String?
    @State private var pullTask: Task<Void, Never>?
    @State private var isRechecking = false

    private let recommendation = ModelRecommender.recommendationForThisMac()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcomeStep
                case .backend: backendStep
                case .features: featuresStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 480)
        .background(AppTheme.Colors.backgroundPrimary)
        .onDisappear { pullTask?.cancel() }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 56))
                .foregroundStyle(AppTheme.Colors.accentPrimary)
            Text("Welcome to LocalMind")
                .font(.system(size: 26, weight: .bold))
            Text("A private AI assistant that reads your documents, remembers your conversations, and works on a schedule — without a single byte leaving your Mac.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.xl)

            HStack(spacing: AppTheme.Spacing.lg) {
                privacyBadge("No cloud")
                privacyBadge("No telemetry")
                privacyBadge("No subscription")
            }
            Spacer()
            Button("Get Started") {
                withAnimation { step = .backend }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, AppTheme.Spacing.xl)
        }
    }

    private func privacyBadge(_ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.accentPrimary)
            Text(label)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(AppTheme.Colors.backgroundTertiary))
    }

    // MARK: - Step 2: Backend setup

    /// Ready when any backend is connected AND (for Ollama) at least one
    /// model is installed to answer with.
    private var backendReady: Bool {
        switch aiManager.currentBackend {
        case .none: return false
        case .ollama: return !aiManager.availableModels.isEmpty
        case .appleFoundationModels, .openAICompatible: return true
        }
    }

    private var ollamaConnectedButEmpty: Bool {
        aiManager.currentBackend == .ollama && aiManager.availableModels.isEmpty
    }

    private var backendStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up your AI")
                    .font(.system(size: 22, weight: .bold))
                Text("LocalMind talks to AI running on this Mac. One backend is enough to start.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, AppTheme.Spacing.xl)

            if backendReady {
                readyCard
            } else if ollamaConnectedButEmpty {
                pullModelCard
            } else {
                noBackendCard
            }

            Spacer()

            HStack {
                Button("Back") { withAnimation { step = .welcome } }
                Spacer()
                if backendReady {
                    Button("Continue") { withAnimation { step = .features } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    // Never a dead end: exploring the app without a backend is
                    // allowed, it just can't answer yet.
                    Button("Skip for now") { withAnimation { step = .features } }
                }
            }
            .padding(.bottom, AppTheme.Spacing.xl)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
    }

    private var readyCard: some View {
        setupCard(icon: "checkmark.circle.fill", iconColor: .green) {
            Text("You're ready")
                .font(.system(size: 15, weight: .semibold))
            Text("Connected to \(aiManager.statusMessage.isEmpty ? "a local backend" : aiManager.statusMessage). Your first conversation is one click away.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var noBackendCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            setupCard(icon: "arrow.down.circle.fill", iconColor: AppTheme.Colors.accentPrimary) {
                Text("Get Ollama (recommended)")
                    .font(.system(size: 15, weight: .semibold))
                Text("Free, open source, and the easiest way to run AI models locally. Install it, then come back here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Download Ollama") {
                        openURL("https://ollama.com/download/mac")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        recheckBackends()
                    } label: {
                        if isRechecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Check again")
                        }
                    }
                    .disabled(isRechecking)
                }
            }

            setupCard(icon: "apple.logo", iconColor: AppTheme.Colors.textSecondary) {
                Text("Apple Intelligence")
                    .font(.system(size: 15, weight: .semibold))
                Text("On Apple Silicon Macs with Apple Intelligence enabled, LocalMind works with zero setup — it's detected automatically when available.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pullModelCard: some View {
        setupCard(icon: "square.and.arrow.down.fill", iconColor: AppTheme.Colors.accentPrimary) {
            Text("Ollama is running — now it needs a model")
                .font(.system(size: 15, weight: .semibold))
            Text("For this Mac (\(ModelRecommender.installedMemoryGB) GB memory), we recommend **\(recommendation.modelID)** (\(recommendation.downloadSize)). \(recommendation.reason)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if isPulling {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = pullFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(pullStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Download \(recommendation.modelID)") {
                        startRecommendedPull()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Check again") { recheckBackends() }
                        .disabled(isRechecking)
                }
            }

            if let pullError {
                Text(pullError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func setupCard(icon: String, iconColor: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(iconColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AppTheme.Colors.backgroundSecondary)
        )
    }

    // MARK: - Step 3: What LocalMind can do

    private var featuresStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What LocalMind can do")
                    .font(.system(size: 22, weight: .bold))
                Text("A few things worth discovering early — all private, all on-device.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, AppTheme.Spacing.xl)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                featureRow(icon: "doc.text.magnifyingglass",
                           title: "Chat with your documents",
                           detail: "Drop PDFs or watch a folder — answers cite their sources.")
                featureRow(icon: "person.2.fill",
                           title: "Agents & pipelines",
                           detail: "Reusable personas, chained into workflows like draft → critique → revise.")
                featureRow(icon: "clock.badge.checkmark",
                           title: "Automations",
                           detail: "\"Every morning, summarize what's new in my documents.\"")
                featureRow(icon: "waveform",
                           title: "Voice mode",
                           detail: "A hands-free spoken conversation — speak, pause, hear the answer.")
                featureRow(icon: "keyboard",
                           title: "Ask from anywhere",
                           detail: "A global shortcut opens a floating bubble over any app (enable in Settings).")
            }

            Spacer()

            HStack {
                Button("Back") { withAnimation { step = .backend } }
                Spacer()
                Button("Start Chatting") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, AppTheme.Spacing.xl)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(AppTheme.Colors.accentPrimary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func recheckBackends() {
        isRechecking = true
        Task {
            await aiManager.detectAndConnect()
            isRechecking = false
        }
    }

    private func startRecommendedPull() {
        guard !isPulling else { return }
        isPulling = true
        pullError = nil
        pullStatus = "Starting download…"
        pullFraction = nil

        pullTask = Task {
            do {
                for try await progress in aiManager.pullOllamaModel(recommendation.modelID) {
                    if Task.isCancelled { break }
                    pullStatus = progress.status
                    if let fraction = progress.fraction {
                        pullFraction = fraction
                    }
                }
                if !Task.isCancelled {
                    await aiManager.refreshModelList()
                    await aiManager.detectAndConnect()
                }
            } catch {
                if !Task.isCancelled {
                    pullError = error.localizedDescription
                }
            }
            isPulling = false
        }
    }

    private func openURL(_ string: String) {
        #if os(macOS)
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
