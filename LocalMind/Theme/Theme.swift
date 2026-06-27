//
//  Theme.swift
//  LocalAIHelper
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI
import AppKit

/// Creates a Color that adapts to the drawing appearance. Uses
/// `bestMatch(from:)` instead of a direct name comparison so it handles
/// every dark variant macOS may report (darkAqua, accessibilityHighContrast
/// variants, etc.) — the previous `$0.name == .darkAqua` check missed those.
private func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight])
        switch match {
        case .darkAqua, .vibrantDark: return dark
        default: return light
        }
    })
}

/// Central design system for LocalAIHelper
enum AppTheme {
    
    // MARK: - Colors
    
    enum Colors {
        // Backgrounds
        static let backgroundPrimary = adaptiveColor(light: .white, dark: .black)
        static let backgroundSecondary = adaptiveColor(light: NSColor(white: 0.95, alpha: 1.0), dark: NSColor(white: 0.05, alpha: 1.0))
        static let backgroundTertiary = adaptiveColor(light: NSColor(white: 0.92, alpha: 1.0), dark: NSColor(white: 0.08, alpha: 1.0))
        static let sidebarBackground = adaptiveColor(light: NSColor(white: 0.97, alpha: 1.0), dark: .black)

        // Accents
        static let accentPrimary = adaptiveColor(light: .black, dark: .white)
        static let accentSecondary = adaptiveColor(light: NSColor(white: 0.3, alpha: 1.0), dark: NSColor(white: 0.7, alpha: 1.0))
        static let accentGreen = adaptiveColor(light: NSColor(white: 0.15, alpha: 1.0), dark: NSColor(white: 0.85, alpha: 1.0))
        static let accentOrange = adaptiveColor(light: NSColor(white: 0.4, alpha: 1.0), dark: NSColor(white: 0.6, alpha: 1.0))
        static let accentRed = adaptiveColor(light: NSColor(white: 0.5, alpha: 1.0), dark: NSColor(white: 0.5, alpha: 1.0))

        // Text
        static let textPrimary = adaptiveColor(light: .black, dark: .white)
        static let textSecondary = adaptiveColor(light: NSColor(white: 0.4, alpha: 1.0), dark: NSColor(white: 0.6, alpha: 1.0))
        static let textTertiary = adaptiveColor(light: NSColor(white: 0.6, alpha: 1.0), dark: NSColor(white: 0.38, alpha: 1.0))

        // Borders & Dividers
        static let border = adaptiveColor(light: NSColor(white: 0.0, alpha: 0.1), dark: NSColor(white: 1.0, alpha: 0.1))
        static let divider = adaptiveColor(light: NSColor(white: 0.0, alpha: 0.08), dark: NSColor(white: 1.0, alpha: 0.08))

        // Interaction
        static let hover = adaptiveColor(light: NSColor(white: 0.0, alpha: 0.06), dark: NSColor(white: 1.0, alpha: 0.06))
        static let hoverSubtle = adaptiveColor(light: NSColor(white: 0.0, alpha: 0.03), dark: NSColor(white: 1.0, alpha: 0.03))

        // Gradients
        static let accentGradient = LinearGradient(
            colors: [accentPrimary, adaptiveColor(light: NSColor(white: 0.35, alpha: 1.0), dark: NSColor(white: 0.65, alpha: 1.0))],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let subtleGradient = LinearGradient(
            colors: [
                adaptiveColor(light: NSColor(white: 0.0, alpha: 0.04), dark: NSColor(white: 1.0, alpha: 0.06)),
                adaptiveColor(light: NSColor(white: 0.0, alpha: 0.01), dark: NSColor(white: 1.0, alpha: 0.02))
            ],
            startPoint: .top,
            endPoint: .bottom
        )

        // Status
        static let statusOnline = Color(red: 0.2, green: 0.84, blue: 0.4)
        static let statusOffline = Color(red: 0.9, green: 0.25, blue: 0.25)
        static let statusChecking = adaptiveColor(light: NSColor(white: 0.4, alpha: 1.0), dark: NSColor(white: 0.6, alpha: 1.0))
    }
    
    // MARK: - Typography
    
    enum Typography {
        static let largeTitle = Font.system(size: 28, weight: .bold, design: .rounded)
        static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let title2 = Font.system(size: 17, weight: .semibold, design: .rounded)
        static let headline = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 14, weight: .regular)
        static let callout = Font.system(size: 13, weight: .regular)
        static let caption = Font.system(size: 12, weight: .medium)
        static let captionSecondary = Font.system(size: 11, weight: .regular)
        static let code = Font.system(size: 13, weight: .regular, design: .monospaced)
    }
    
    // MARK: - Spacing
    
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }
    
    // MARK: - Dimensions
    
    enum Dimensions {
        static let cornerRadiusSmall: CGFloat = 8
        static let cornerRadius: CGFloat = 12
        static let cornerRadiusLarge: CGFloat = 16
        static let cornerRadiusXL: CGFloat = 20
        
        static let sidebarWidth: CGFloat = 260
        static let sidebarMinWidth: CGFloat = 200
        static let sidebarMaxWidth: CGFloat = 320
        
        static let inputBarHeight: CGFloat = 52
        static let buttonHeight: CGFloat = 36
        static let iconSize: CGFloat = 20
        static let avatarSize: CGFloat = 32
        
        static let minWindowWidth: CGFloat = 900
        static let minWindowHeight: CGFloat = 600
    }
    
    // MARK: - Shadows
    
    enum Shadows {
        static let small = ShadowStyle(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        static let medium = ShadowStyle(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        static let large = ShadowStyle(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
        static let glow = ShadowStyle(color: Colors.accentPrimary.opacity(0.3), radius: 12, x: 0, y: 0)
    }
    
    // MARK: - Animation
    
    enum Animations {
        static let quick = Animation.easeOut(duration: 0.15)
        static let standard = Animation.easeInOut(duration: 0.25)
        static let smooth = Animation.easeInOut(duration: 0.35)
        static let spring = Animation.spring(response: 0.4, dampingFraction: 0.8)
        static let bouncy = Animation.spring(response: 0.35, dampingFraction: 0.6)
    }
}

// MARK: - Shadow Helper

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension View {
    func shadow(_ style: ShadowStyle) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
