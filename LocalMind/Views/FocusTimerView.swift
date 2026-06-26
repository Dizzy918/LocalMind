//
//  FocusTimerView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI
import UserNotifications

/// Pomodoro-style Focus Timer with AI-generated session goals
struct FocusTimerView: View {
    let aiManager: AIServiceManager
    let dataStore: DataStore
    
    @State private var selectedPreset: FocusDurationPreset = .short
    @State private var customMinutes: Int = 25
    @State private var currentSession: FocusSession?
    @State private var remainingSeconds: Int = 0
    @State private var timerActive = false
    @State private var timer: Timer?
    @State private var aiGoal = ""
    @State private var isGeneratingGoal = false
    @State private var goalContext = ""
    @State private var showHistory = false
    
    private var progress: Double {
        guard let session = currentSession else { return 0 }
        let total = Double(session.durationSeconds)
        let elapsed = total - Double(remainingSeconds)
        return total > 0 ? elapsed / total : 0
    }
    
    private var timeString: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            
            Divider().overlay(AppTheme.Colors.divider)
            
            ScrollView {
                VStack(spacing: AppTheme.Spacing.xxl) {
                    Spacer(minLength: AppTheme.Spacing.xl)
                    
                    // Timer display
                    timerDisplay
                    
                    // Controls
                    timerControls
                    
                    // AI Goal
                    goalSection
                    
                    // Session history
                    if !dataStore.focusSessions.isEmpty {
                        historySection
                    }
                    
                    Spacer()
                }
                .padding(AppTheme.Spacing.xl)
            }
        }
        .background(AppTheme.Colors.backgroundPrimary)
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            Image(systemName: "timer")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(AppTheme.Colors.accentGradient)
            
            Text("Focus Timer")
                .font(AppTheme.Typography.title2)
                .foregroundStyle(AppTheme.Colors.textPrimary)
            
            Spacer()
            
            if timerActive {
                HStack(spacing: AppTheme.Spacing.xs) {
                    PulsingDot(color: AppTheme.Colors.accentGreen, size: 8)
                    Text("In Focus")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.accentGreen)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
    }
    
    // MARK: - Timer Display
    
    private var timerDisplay: some View {
        ZStack {
            // Progress ring
            AnimatedProgressRing(
                progress: progress,
                lineWidth: 10,
                size: 200,
                gradient: timerActive
                    ? LinearGradient(
                        colors: [AppTheme.Colors.accentGreen, AppTheme.Colors.accentPrimary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : AppTheme.Colors.accentGradient
            )
            
            // Time display
            VStack(spacing: AppTheme.Spacing.xs) {
                Text(timeString)
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .contentTransition(.numericText())
                
                Text(timerActive ? "Stay focused!" : "Ready?")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }
        }
    }
    
    // MARK: - Timer Controls
    
    private var timerControls: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            if !timerActive {
                // Duration presets
                HStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(FocusDurationPreset.allCases, id: \.self) { preset in
                        Button {
                            withAnimation(AppTheme.Animations.quick) {
                                selectedPreset = preset
                                customMinutes = preset.rawValue
                                remainingSeconds = preset.rawValue * 60
                            }
                        } label: {
                            Text(preset.displayName)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(
                                    selectedPreset == preset
                                        ? AppTheme.Colors.textPrimary
                                        : AppTheme.Colors.textSecondary
                                )
                                .padding(.horizontal, AppTheme.Spacing.lg)
                                .padding(.vertical, AppTheme.Spacing.sm)
                                .background {
                                    RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                                        .fill(
                                            selectedPreset == preset
                                                ? AppTheme.Colors.accentPrimary.opacity(0.15)
                                                : AppTheme.Colors.backgroundTertiary
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                                                .stroke(
                                                    selectedPreset == preset
                                                        ? AppTheme.Colors.accentPrimary.opacity(0.3)
                                                        : AppTheme.Colors.border,
                                                    lineWidth: 1
                                                )
                                        }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // Start / Stop button
            HStack(spacing: AppTheme.Spacing.md) {
                if timerActive {
                    Button {
                        stopTimer(completed: false)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14))
                            Text("Stop")
                                .font(AppTheme.Typography.headline)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppTheme.Spacing.xl)
                        .padding(.vertical, AppTheme.Spacing.md)
                        .background {
                            RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                                .fill(AppTheme.Colors.accentRed)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    GradientButton("Start Focus", icon: "play.fill") {
                        startTimer()
                    }
                }
            }
        }
    }
    
    // MARK: - Goal Section
    
    private var goalSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Text("SESSION GOAL")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .tracking(1.2)
                    
                    Spacer()
                    
                    if !timerActive {
                        Button {
                            generateGoal()
                        } label: {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11))
                                Text(isGeneratingGoal ? "Thinking..." : "AI Suggest")
                                    .font(AppTheme.Typography.caption)
                            }
                            .foregroundStyle(AppTheme.Colors.accentPrimary)
                        }
                        .buttonStyle(.plain)
                        .disabled(isGeneratingGoal)
                    }
                }
                
                TextField("What will you focus on this session?", text: $goalContext, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(2...4)
                    .disabled(timerActive)
                
                if !aiGoal.isEmpty {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("AI Suggestion:")
                            .font(AppTheme.Typography.captionSecondary)
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                        
                        Text(aiGoal)
                            .font(AppTheme.Typography.callout)
                            .foregroundStyle(AppTheme.Colors.accentPrimary)
                            .padding(AppTheme.Spacing.sm)
                            .background {
                                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                                    .fill(AppTheme.Colors.accentPrimary.opacity(0.08))
                            }
                        
                        Button("Use this goal") {
                            goalContext = aiGoal
                            aiGoal = ""
                        }
                        .buttonStyle(.plain)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.accentPrimary)
                    }
                }
            }
        }
        .frame(maxWidth: 500)
    }
    
    // MARK: - History
    
    private var historySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("RECENT SESSIONS")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .tracking(1.2)
                
                Spacer()
                
                let completedCount = dataStore.focusSessions.filter(\.wasCompleted).count
                Text("\(completedCount) completed")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(AppTheme.Colors.accentGreen)
            }
            
            ForEach(dataStore.focusSessions.prefix(5)) { session in
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: session.wasCompleted ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(
                            session.wasCompleted ? AppTheme.Colors.accentGreen : AppTheme.Colors.textTertiary
                        )
                    
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(session.aiGeneratedGoal.isEmpty ? "\(session.durationMinutes) min session" : session.aiGeneratedGoal)
                            .font(AppTheme.Typography.callout)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                        
                        if let completedAt = session.completedAt {
                            Text(completedAt.formatted(.relative(presentation: .named)))
                                .font(AppTheme.Typography.captionSecondary)
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                        }
                    }
                    
                    Spacer()
                    
                    Text("\(session.durationMinutes) min")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .padding(AppTheme.Spacing.md)
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                        .fill(AppTheme.Colors.backgroundTertiary)
                }
            }
        }
        .frame(maxWidth: 500)
    }
    
    // MARK: - Timer Actions
    
    private func startTimer() {
        let session = FocusSession(
            durationMinutes: customMinutes,
            aiGeneratedGoal: goalContext,
            startedAt: Date()
        )
        currentSession = session
        remainingSeconds = session.durationSeconds
        timerActive = true
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if remainingSeconds > 0 {
                withAnimation(.linear(duration: 0.3)) {
                    remainingSeconds -= 1
                }
            } else {
                stopTimer(completed: true)
            }
        }
    }
    
    private func stopTimer(completed: Bool) {
        timer?.invalidate()
        timer = nil
        timerActive = false
        
        if var session = currentSession {
            session.completedAt = Date()
            session.wasCompleted = completed
            session.userNotes = goalContext
            dataStore.saveFocusSession(session)
            
            if completed {
                sendCompletionNotification()
            }
        }
        
        currentSession = nil
        remainingSeconds = customMinutes * 60
    }
    
    private func generateGoal() {
        guard let service = aiManager.currentService else { return }
        
        isGeneratingGoal = true
        aiGoal = ""
        
        Task {
            let prompt = """
            Suggest a specific, actionable focus goal for a \(customMinutes)-minute focus session.
            \(goalContext.isEmpty ? "" : "Context: \(goalContext)")
            Keep it to one concise sentence. Be specific and motivating.
            Respond with ONLY the goal, nothing else.
            """
            
            do {
                aiGoal = try await service.generateOnce(prompt: prompt, systemPrompt: "You are a productivity coach. Suggest specific, achievable focus goals.")
                aiGoal = aiGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                aiGoal = "Focus deeply on your most important task."
            }
            
            isGeneratingGoal = false
        }
    }
    
    private func sendCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Focus Session Complete! 🎉"
        content.body = "Great work! You stayed focused for \(customMinutes) minutes."
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
}
