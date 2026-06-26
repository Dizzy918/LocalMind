//
//  Components.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = AppTheme.Spacing.lg
    
    init(padding: CGFloat = AppTheme.Spacing.lg, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    }
            }
    }
}

// MARK: - Hover Icon Button

struct HoverIconButton: View {
    let systemName: String
    var size: CGFloat = 20
    var baseColor: Color = AppTheme.Colors.textTertiary
    var hoverColor: Color = AppTheme.Colors.textPrimary
    let helpText: String
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(isHovering ? hoverColor : baseColor)
                .padding(AppTheme.Spacing.xs)
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                        .fill(isHovering ? AppTheme.Colors.hover : Color.clear)
                }
                .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            withAnimation(AppTheme.Animations.quick) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Gradient Button

struct GradientButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    var isCompact: Bool = false
    
    init(_ title: String, icon: String? = nil, isCompact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isCompact = isCompact
        self.action = action
    }
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: isCompact ? 12 : 14, weight: .semibold))
                }
                Text(title)
                    .font(isCompact ? AppTheme.Typography.caption : AppTheme.Typography.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isCompact ? AppTheme.Spacing.md : AppTheme.Spacing.lg)
            .padding(.vertical, isCompact ? AppTheme.Spacing.sm : AppTheme.Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                    .fill(AppTheme.Colors.accentGradient)
                    .shadow(AppTheme.Shadows.glow)
            }
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppTheme.Animations.quick) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Pulsing Dot (Streaming Indicator)

struct PulsingDot: View {
    @State private var isAnimating = false
    var color: Color = AppTheme.Colors.accentPrimary
    var size: CGFloat = 8
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(isAnimating ? 1.3 : 0.8)
            .opacity(isAnimating ? 1.0 : 0.5)
            .animation(
                .easeInOut(duration: 0.8)
                .repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear { isAnimating = true }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotOffset: [Bool] = [false, false, false]
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppTheme.Colors.textTertiary)
                    .frame(width: 6, height: 6)
                    .offset(y: dotOffset[index] ? -4 : 0)
            }
        }
        .onAppear {
            for i in 0..<3 {
                withAnimation(
                    .easeInOut(duration: 0.4)
                    .repeatForever(autoreverses: true)
                    .delay(Double(i) * 0.15)
                ) {
                    dotOffset[i] = true
                }
            }
        }
    }
}

// MARK: - Animated Progress Ring

struct AnimatedProgressRing: View {
    let progress: Double  // 0.0 to 1.0
    var lineWidth: CGFloat = 8
    var size: CGFloat = 120
    var gradient: LinearGradient = AppTheme.Colors.accentGradient
    
    @State private var animatedProgress: Double = 0
    
    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(AppTheme.Colors.border, lineWidth: lineWidth)
            
            // Progress arc
            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(
                    gradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(AppTheme.Animations.smooth, value: animatedProgress)
        }
        .frame(width: size, height: size)
        .onAppear {
            animatedProgress = progress
        }
        .onChange(of: progress) { _, newValue in
            animatedProgress = newValue
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    var onPlay: (() -> Void)? = nil

    init(message: ChatMessage, isStreaming: Bool = false, onPlay: (() -> Void)? = nil) {
        self.message = message
        self.isStreaming = isStreaming
        self.onPlay = onPlay
    }

    private var isUser: Bool { message.role == .user }
    @State private var isHovered = false
    @State private var showCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            if isUser { Spacer(minLength: 80) }

            if !isUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accentPrimary)
                    .frame(width: 28, height: 28)
                    .background {
                        Circle()
                            .fill(AppTheme.Colors.accentPrimary.opacity(0.12))
                    }
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if isUser {
                        Text("You")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                    } else {
                        Text("LocalMind")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                    }

                    if isStreaming && !isUser {
                        PulsingDot(size: 6)
                    }
                }

                // Message content
                VStack(alignment: isUser ? .trailing : .leading, spacing: AppTheme.Spacing.sm) {
                    #if canImport(AppKit)
                    if let imageData = message.imageData, let nsImage = NSImage(data: imageData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 300, maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall))
                    }
                    #elseif canImport(UIKit)
                    if let imageData = message.imageData, let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 300, maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall))
                    }
                    #endif

                    if let fileName = message.attachedFileName {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 14))
                                .foregroundStyle(AppTheme.Colors.accentPrimary)
                                .frame(width: 28, height: 28)
                                .background(AppTheme.Colors.accentPrimary.opacity(0.12))
                                .cornerRadius(6)
                            Text(fileName)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .background(AppTheme.Colors.backgroundSecondary.opacity(0.6))
                        .cornerRadius(AppTheme.Dimensions.cornerRadiusSmall)
                    }

                    MessageMarkdownView(text: displayContent(for: message))
                }
                .padding(isUser ? AppTheme.Spacing.md : 0)
                .background {
                    if isUser {
                        RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusLarge)
                            .fill(AppTheme.Colors.accentPrimary.opacity(0.12))
                    }
                }

                // Action bar — visible on hover for AI, always hidden for user
                if !isUser && (isHovered || showCopied) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        MessageActionButton(icon: showCopied ? "checkmark" : "doc.on.doc", label: showCopied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            showCopied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                showCopied = false
                            }
                        }

                        if let onPlay {
                            MessageActionButton(icon: "speaker.wave.2", label: "Read aloud", action: onPlay)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if !isUser { Spacer(minLength: 80) }
        }
        .onHover { hovering in
            withAnimation(AppTheme.Animations.quick) { isHovered = hovering }
        }
    }

    private func displayContent(for message: ChatMessage) -> String {
        guard message.attachedFileName != nil else { return message.content }
        if let range = message.content.range(of: "\n\n📄 Attached file:") {
            let userText = String(message.content[message.content.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return userText.isEmpty ? "Analyze this file" : userText
        }
        return message.content
    }
}

struct MessageActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(isHovered ? AppTheme.Colors.textPrimary : AppTheme.Colors.textTertiary)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? AppTheme.Colors.hover : AppTheme.Colors.backgroundTertiary)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(AppTheme.Colors.border, lineWidth: 0.5)
                    }
            }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(AppTheme.Animations.quick) { isHovered = h } }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let backend: AIBackend
    let statusMessage: String
    var isCompact: Bool = false
    
    private var statusColor: Color {
        switch backend {
        case .appleFoundationModels, .ollama, .openAICompatible:
            return AppTheme.Colors.statusOnline
        case .none:
            return AppTheme.Colors.statusOffline
        }
    }
    
    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .help(isCompact ? statusMessage : "")
            
            if !isCompact {
                Text(statusMessage)
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, isCompact ? 0 : AppTheme.Spacing.md)
        .padding(.vertical, isCompact ? 0 : AppTheme.Spacing.xs)
        .background {
            if !isCompact {
                Capsule()
                    .fill(statusColor.opacity(0.1))
                    .overlay {
                        Capsule().stroke(statusColor.opacity(0.2), lineWidth: 1)
                    }
            }
        }
    }
}

// MARK: - Tool Button (Sidebar)

struct ToolButton: View {
    let icon: String
    let displayName: String
    let isSelected: Bool
    var isCompact: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: isCompact ? 0 : AppTheme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(
                        isSelected ? AppTheme.Colors.accentPrimary : AppTheme.Colors.textSecondary
                    )
                    .frame(width: 28, height: 28)
                
                if !isCompact {
                    Text(displayName)
                        .font(AppTheme.Typography.headline)
                        .foregroundStyle(
                            isSelected ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary
                        )
                        .lineLimit(1)
                    
                    Spacer()
                }
            }
            .padding(.horizontal, isCompact ? AppTheme.Spacing.xs : AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                    .fill(
                        isSelected
                            ? AppTheme.Colors.accentPrimary.opacity(0.12)
                            : (isHovered ? AppTheme.Colors.hoverSubtle : Color.clear)
                    )
            }
            .help(isCompact ? displayName : "")
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppTheme.Animations.quick) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    var isCompact: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: isCompact ? 0 : AppTheme.Spacing.md) {
                let isGenerating = conversation.title == "New Conversation" && conversation.emoji == nil
                
                // Display emoji icon for the conversation or a spinner if generating
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 22)
                } else {
                    Text(conversation.displayEmoji)
                        .font(.system(size: 14))
                        .frame(width: 22, height: 22)
                }
                
                if !isCompact {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(isGenerating ? "Generating..." : conversation.title)
                            .font(AppTheme.Typography.callout)
                            .foregroundStyle(
                                isSelected ? AppTheme.Colors.textPrimary : (isGenerating ? AppTheme.Colors.textTertiary : AppTheme.Colors.textSecondary)
                            )
                            .lineLimit(1)
                        
                        Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                            .font(AppTheme.Typography.captionSecondary)
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                }
            }
            .padding(.horizontal, isCompact ? AppTheme.Spacing.xs : AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                    .fill(
                        isSelected
                            ? AppTheme.Colors.accentPrimary.opacity(0.1)
                            : (isHovered ? AppTheme.Colors.hoverSubtle : Color.clear)
                    )
            }
            .help(isCompact ? conversation.title : "")
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppTheme.Animations.quick) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Suggestion Chip

struct SuggestionChip: View {
    let icon: String
    let text: String
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(text)
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }
            .padding(AppTheme.Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                    .fill(isHovered ? AppTheme.Colors.hover : AppTheme.Colors.backgroundTertiary.opacity(0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                            .stroke(AppTheme.Colors.border, lineWidth: 0.5)
                    }
            }
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(AppTheme.Animations.quick) { isHovered = h }
        }
    }
}

// MARK: - Audio Level Indicator

struct AudioLevelIndicator: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let barHeight = CGFloat(4 + Int(CGFloat(level) * 12) * (i % 3 == 1 ? 1 : (i % 2 == 0 ? 1 : 1)))
                    + CGFloat.random(in: 0...CGFloat(level) * 6)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 2, height: max(3, barHeight))
                    .animation(.easeInOut(duration: 0.1), value: level)
            }
        }
        .frame(height: 16)
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(AppTheme.Colors.textTertiary)
            
            VStack(spacing: AppTheme.Spacing.sm) {
                Text(title)
                    .font(AppTheme.Typography.title2)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                
                Text(subtitle)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .padding(AppTheme.Spacing.xxxl)
    }
}
