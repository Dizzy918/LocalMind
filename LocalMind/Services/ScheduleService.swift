//
//  ScheduleService.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import Foundation

/// A prompt that runs on a schedule — "every morning, summarize X". Results
/// arrive as normal conversations with the sidebar's unread dot.
nonisolated struct ScheduledRun: Identifiable, Codable, Sendable, Hashable {
    enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily
        case weekdays

        var displayName: String {
            switch self {
            case .daily: return "Every day"
            case .weekdays: return "Weekdays"
            }
        }
    }

    let id: UUID
    var name: String
    var prompt: String
    /// Agent that answers; nil = default assistant.
    var agentID: UUID?
    var hour: Int
    var minute: Int
    var frequency: Frequency
    var enabled: Bool
    var lastRunDate: Date?

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        agentID: UUID? = nil,
        hour: Int = 9,
        minute: Int = 0,
        frequency: Frequency = .daily,
        enabled: Bool = true,
        lastRunDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.agentID = agentID
        self.hour = hour
        self.minute = minute
        self.frequency = frequency
        self.enabled = enabled
        self.lastRunDate = lastRunDate
    }
}

/// Fires scheduled runs while the app is open (LocalMind lives in the menu
/// bar, so "open" is the common case). A run that was missed earlier in the
/// day catches up on the next tick — launching at 9:47 still runs the 9:00
/// morning briefing.
@Observable
@MainActor
final class ScheduleService {
    private(set) var runs: [ScheduledRun] = []

    private let dataStore: DataStore
    private let generationService: ChatGenerationService
    private let fileURL: URL
    private var timer: Timer?

    init(dataStore: DataStore, generationService: ChatGenerationService, fileURLOverride: URL? = nil, startTicking: Bool = true) {
        self.dataStore = dataStore
        self.generationService = generationService
        if let fileURLOverride {
            fileURL = fileURLOverride
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalMind", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("scheduled_runs.json")
        }
        load()
        if startTicking {
            startTimer()
        }
    }

    // MARK: - CRUD

    func save(_ run: ScheduledRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        persist()
    }

    func delete(_ run: ScheduledRun) {
        runs.removeAll { $0.id == run.id }
        persist()
    }

    // MARK: - Scheduling

    /// Pure due-check so the logic is unit-testable: due when the scheduled
    /// time has passed today, it hasn't already run today, and the frequency
    /// allows today.
    nonisolated static func isDue(_ run: ScheduledRun, now: Date, calendar: Calendar) -> Bool {
        guard run.enabled else { return false }
        if run.frequency == .weekdays {
            let weekday = calendar.component(.weekday, from: now)
            if weekday == 1 || weekday == 7 { return false } // Sunday / Saturday
        }
        guard let scheduledToday = calendar.date(bySettingHour: run.hour, minute: run.minute, second: 0, of: now),
              now >= scheduledToday else { return false }
        if let last = run.lastRunDate, calendar.isDate(last, inSameDayAs: now) { return false }
        return true
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        // Catch up anything already due right after launch.
        Task { @MainActor [weak self] in
            self?.tick()
        }
    }

    func tick(now: Date = Date()) {
        // Hold off until a run can actually succeed and be delivered: right
        // after launch backend detection is still in flight, and before
        // sign-in the result conversation would be orphaned (profile-less).
        // lastRunDate isn't stamped until fire(), so the 30-second timer
        // retries and the catch-up behaviour is preserved.
        guard generationService.hasAvailableBackend,
              UserDefaults.standard.string(forKey: "activeProfileID") != nil else { return }
        let calendar = Calendar.current
        for run in runs where Self.isDue(run, now: now, calendar: calendar) {
            fire(run, at: now)
        }
    }

    private func fire(_ run: ScheduledRun, at date: Date) {
        var updated = run
        updated.lastRunDate = date
        save(updated)

        // The result is a plain conversation — the unread dot delivers it.
        let stamp = date.formatted(date: .abbreviated, time: .omitted)
        let conversation = Conversation(
            title: "⏰ \(run.name) — \(stamp)",
            messages: [ChatMessage(role: .user, content: run.prompt)],
            toolType: .chat,
            emoji: "⏰",
            agentID: run.agentID
        )
        dataStore.saveConversation(conversation)
        generationService.start(conversationID: conversation.id)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ScheduledRun].self, from: data) else { return }
        runs = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(runs) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
