//
//  VoiceModeView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import SwiftUI

/// Hands-free conversation: listen → detect the end of speech → generate →
/// speak the answer → listen again, until the user ends the session.
/// Everything (recognition, generation, synthesis) runs on-device/local.
struct VoiceModeView: View {
    let aiManager: AIServiceManager
    let generationService: ChatGenerationService
    let voiceManager: VoiceManager
    @Binding var conversation: Conversation
    let dataStore: DataStore
    let onClose: () -> Void

    private enum Phase {
        case idle          // waiting to start / permissions
        case listening
        case thinking      // generation in flight
        case speaking
    }

    @State private var phase: Phase = .idle
    @State private var silenceTask: Task<Void, Never>?
    @State private var statusText = "Starting…"

    /// How long a pause ends the utterance and sends it. User-adjustable —
    /// 1.8s is too quick for slow speakers and too slow for rapid back-and-forth.
    @AppStorage("voiceSilenceWindow") private var silenceWindowSeconds = 1.8

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Mode")
                        .font(AppTheme.Typography.headline)
                    Text("Speak, pause, get an answer out loud — hands-free.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("End", action: endSession)
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            orb
                .onTapGesture(perform: advancePhaseManually)
                .help(orbHelp)

            Text(phaseLabel)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Group {
                if phase == .listening, !voiceManager.transcribedText.isEmpty {
                    Text(voiceManager.transcribedText)
                } else if let error = voiceManager.errorMessage {
                    Text(error).foregroundStyle(AppTheme.Colors.accentOrange)
                } else {
                    Text(statusText)
                }
            }
            .font(AppTheme.Typography.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(minHeight: 48, alignment: .top)
            .padding(.horizontal, AppTheme.Spacing.xl)

            Spacer()

            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Pause to send")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                Slider(value: $silenceWindowSeconds, in: 1.0...4.0, step: 0.2)
                    .frame(width: 140)
                Text(String(format: "%.1fs", silenceWindowSeconds))
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .leading)
            }

            Text("Tap the orb to \(orbHelp.lowercased()) · Esc to end")
                .font(AppTheme.Typography.captionSecondary)
                .foregroundStyle(.tertiary)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 420, height: 460)
        .onAppear(perform: beginListening)
        .onDisappear(perform: teardown)
        .onChange(of: voiceManager.transcribedText) { _, newText in
            scheduleSilenceSend(for: newText)
        }
        .onChange(of: conversation.messages.count) { oldCount, newCount in
            // The generation service delivered the answer — read it aloud.
            guard phase == .thinking, newCount > oldCount,
                  let last = conversation.messages.last, last.role == .assistant else { return }
            phase = .speaking
            statusText = String(last.content.prefix(220))
            voiceManager.speak(text: last.content)
        }
        .onChange(of: voiceManager.isSpeaking) { wasSpeaking, isSpeaking in
            // Finished reading the answer → open the mic again.
            guard phase == .speaking, wasSpeaking, !isSpeaking else { return }
            beginListening()
        }
    }

    // MARK: - Orb

    private var orb: some View {
        ZStack {
            Circle()
                .fill(orbColor.opacity(0.15))
                .frame(width: 160, height: 160)
                .scaleEffect(orbPulse)
                .animation(.easeInOut(duration: 0.25), value: orbPulse)
            Circle()
                .fill(orbColor.opacity(0.3))
                .frame(width: 110, height: 110)
                .scaleEffect(orbPulse)
                .animation(.easeInOut(duration: 0.2), value: orbPulse)
            Circle()
                .fill(orbColor)
                .frame(width: 72, height: 72)
            Image(systemName: orbIcon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
        }
        .contentShape(Circle())
    }

    private var orbColor: Color {
        switch phase {
        case .idle: return AppTheme.Colors.textTertiary
        case .listening: return .blue
        case .thinking: return .purple
        case .speaking: return .green
        }
    }

    private var orbIcon: String {
        switch phase {
        case .idle: return "mic.slash"
        case .listening: return "mic.fill"
        case .thinking: return "brain"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    /// Listening: swells with your voice. Other phases: gentle steady size.
    private var orbPulse: CGFloat {
        phase == .listening ? 1 + CGFloat(voiceManager.audioLevel) * 0.5 : 1
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: return "Paused"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        }
    }

    private var orbHelp: String {
        switch phase {
        case .idle: return "Start listening"
        case .listening: return "Send now"
        case .thinking: return "Thinking (tap does nothing)"
        case .speaking: return "Skip to listening"
        }
    }

    // MARK: - Session flow

    private func beginListening() {
        guard !generationService.isStreaming(conversation.id) else {
            phase = .thinking
            statusText = "Answering…"
            return
        }
        phase = .listening
        statusText = "Say something — a pause sends it."
        if !voiceManager.isRecording {
            voiceManager.toggleRecording()
        }
    }

    /// A pause in speech ends the utterance: reset the countdown on every
    /// transcript change, send when it expires.
    private func scheduleSilenceSend(for text: String) {
        silenceTask?.cancel()
        guard phase == .listening,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        silenceTask = Task {
            try? await Task.sleep(for: .seconds(silenceWindowSeconds))
            guard !Task.isCancelled else { return }
            sendUtterance()
        }
    }

    private func sendUtterance() {
        let text = voiceManager.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .listening, !text.isEmpty else { return }
        silenceTask?.cancel()
        voiceManager.stopRecording()

        conversation.messages.append(ChatMessage(role: .user, content: text))
        conversation.updateTitleIfNeeded()
        conversation.updatedAt = Date()
        dataStore.saveConversation(conversation)

        phase = .thinking
        statusText = "Answering…"
        generationService.start(conversationID: conversation.id)
    }

    private func advancePhaseManually() {
        switch phase {
        case .idle:
            beginListening()
        case .listening:
            sendUtterance()
        case .thinking:
            break
        case .speaking:
            voiceManager.stopSpeaking()
            beginListening()
        }
    }

    private func endSession() {
        teardown()
        onClose()
    }

    private func teardown() {
        silenceTask?.cancel()
        if voiceManager.isRecording {
            voiceManager.stopRecording()
        }
        voiceManager.stopSpeaking()
        phase = .idle
    }
}
