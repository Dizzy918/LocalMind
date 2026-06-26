//
//  FocusSession.swift
//  LocalAIHelper
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation

struct FocusSession: Identifiable, Codable, Sendable {
    let id: UUID
    var durationMinutes: Int
    var aiGeneratedGoal: String
    var userNotes: String
    var startedAt: Date?
    var completedAt: Date?
    var wasCompleted: Bool

    init(
        id: UUID = UUID(),
        durationMinutes: Int = 25,
        aiGeneratedGoal: String = "",
        userNotes: String = "",
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        wasCompleted: Bool = false
    ) {
        self.id = id
        self.durationMinutes = durationMinutes
        self.aiGeneratedGoal = aiGeneratedGoal
        self.userNotes = userNotes
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.wasCompleted = wasCompleted
    }

    var durationSeconds: Int { durationMinutes * 60 }
}

enum FocusDurationPreset: Int, CaseIterable, Sendable {
    case short = 25
    case medium = 45
    case long = 60
    case extraLong = 90

    var displayName: String {
        switch self {
        case .short: return "25 min"
        case .medium: return "45 min"
        case .long: return "60 min"
        case .extraLong: return "90 min"
        }
    }
}
