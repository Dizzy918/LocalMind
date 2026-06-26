//
//  TaskItem.swift
//  LocalAIHelper
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation

enum TaskPriority: String, Codable, Sendable, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case urgent = "Urgent"

    var color: String {
        switch self {
        case .low: return "green"
        case .medium: return "yellow"
        case .high: return "orange"
        case .urgent: return "red"
        }
    }
}

struct SubTask: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var isCompleted: Bool
    var estimatedMinutes: Int?

    init(id: UUID = UUID(), title: String, isCompleted: Bool = false, estimatedMinutes: Int? = nil) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.estimatedMinutes = estimatedMinutes
    }
}

struct TaskPlan: Identifiable, Codable, Sendable {
    let id: UUID
    var goal: String
    var subtasks: [SubTask]
    var estimatedTotalMinutes: Int
    var priority: TaskPriority
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        goal: String,
        subtasks: [SubTask] = [],
        estimatedTotalMinutes: Int = 0,
        priority: TaskPriority = .medium,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.goal = goal
        self.subtasks = subtasks
        self.estimatedTotalMinutes = estimatedTotalMinutes
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var completionPercentage: Double {
        guard !subtasks.isEmpty else { return 0 }
        let completed = subtasks.filter { $0.isCompleted }.count
        return Double(completed) / Double(subtasks.count)
    }

    var completedCount: Int {
        subtasks.filter { $0.isCompleted }.count
    }
}
