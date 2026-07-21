//
//  AppLayout.swift
//  LocalMind
//

import Foundation

/// Which shell the main window wears. Persisted under `AppLayout.storageKey`
/// so menu commands (which live outside any view) can read it too.
enum AppLayout: String, CaseIterable, Identifiable {
    /// The original layout — a permanent sidebar beside a single chat pane.
    case classic
    /// Safari-style — open conversations become tabs in the title bar, and the
    /// sidebar becomes a drawer that's hidden until asked for.
    case tabbed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Sidebar"
        case .tabbed:  return "Tabs"
        }
    }

    var summary: String {
        switch self {
        case .classic: return "Conversation list always visible beside the chat."
        case .tabbed:  return "Open conversations as tabs across the top, like a browser."
        }
    }

    var icon: String {
        switch self {
        case .classic: return "sidebar.left"
        case .tabbed:  return "macwindow.on.rectangle"
        }
    }

    static let storageKey = "appLayout"

    /// Reads the stored layout from outside SwiftUI — the File menu's ⌘W item
    /// needs to know whether to close a tab or the whole window.
    static var current: AppLayout {
        AppLayout(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .classic
    }
}
