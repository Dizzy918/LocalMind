//
//  AutomationsSettingsView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import SwiftUI

/// Settings tab for scheduled runs — prompts that fire on a timetable and
/// deliver their answer as an unread conversation.
struct AutomationsSettingsView: View {
    let scheduleService: ScheduleService
    let dataStore: DataStore

    @State private var editingRun: ScheduledRun?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automations")
                        .font(AppTheme.Typography.title2)
                    Text("Prompts that run on a schedule while LocalMind is open (it lives in your menu bar, so that's most of the time). Results arrive as unread conversations.")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    isCreating = true
                } label: {
                    Label("New Automation", systemImage: "plus")
                }
            }

            if scheduleService.runs.isEmpty {
                VStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "clock.badge")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Try: \"Summarize anything new in my documents\" every morning at 9.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.xl)
            } else {
                List {
                    ForEach(scheduleService.runs) { run in
                        runRow(run)
                    }
                }
                .listStyle(.bordered)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .sheet(isPresented: $isCreating) {
            ScheduledRunEditorView(
                run: nil,
                dataStore: dataStore,
                onSave: { run in
                    scheduleService.save(run)
                    isCreating = false
                },
                onCancel: { isCreating = false }
            )
        }
        .sheet(item: $editingRun) { run in
            ScheduledRunEditorView(
                run: run,
                dataStore: dataStore,
                onSave: { updated in
                    scheduleService.save(updated)
                    editingRun = nil
                },
                onCancel: { editingRun = nil }
            )
        }
    }

    private func runRow(_ run: ScheduledRun) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { run.enabled },
                set: { enabled in
                    var updated = run
                    updated.enabled = enabled
                    scheduleService.save(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.name)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(String(format: "%02d:%02d · %@", run.hour, run.minute, run.frequencyDescription))
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                    if let agent = dataStore.agent(withID: run.agentID) {
                        Text("\(agent.emoji) \(agent.name)")
                            .font(AppTheme.Typography.captionSecondary)
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                    }
                    if let last = run.lastRunDate {
                        Text("last ran \(last.formatted(.relative(presentation: .named)))")
                            .font(AppTheme.Typography.captionSecondary)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Button("Edit") { editingRun = run }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.accentPrimary)
            Button("Delete", role: .destructive) { scheduleService.delete(run) }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.accentRed)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Editor

struct ScheduledRunEditorView: View {
    let dataStore: DataStore
    let onSave: (ScheduledRun) -> Void
    let onCancel: () -> Void

    private let existing: ScheduledRun?

    @State private var name: String
    @State private var prompt: String
    @State private var agentID: UUID?
    @State private var time: Date
    @State private var frequency: ScheduledRun.Frequency
    @State private var weekday: Int

    init(
        run: ScheduledRun?,
        dataStore: DataStore,
        onSave: @escaping (ScheduledRun) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.existing = run
        self.dataStore = dataStore
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: run?.name ?? "")
        _prompt = State(initialValue: run?.prompt ?? "")
        _agentID = State(initialValue: run?.agentID)
        var components = DateComponents()
        components.hour = run?.hour ?? 9
        components.minute = run?.minute ?? 0
        _time = State(initialValue: Calendar.current.date(from: components) ?? Date())
        _frequency = State(initialValue: run?.frequency ?? .daily)
        _weekday = State(initialValue: run?.weekday ?? 2) // Monday
    }

    /// Weekday menu options in Calendar numbering (1 = Sunday … 7 = Saturday),
    /// using the system's localized standalone names.
    private var weekdayNames: [(number: Int, name: String)] {
        let symbols = Calendar.current.standaloneWeekdaySymbols
        return symbols.enumerated().map { ($0.offset + 1, $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text(existing == nil ? "New Automation" : "Edit Automation")
                .font(AppTheme.Typography.title2)

            Form {
                TextField("Name (leave empty to name it after the prompt)", text: $name)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt to run")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $prompt)
                        .font(.system(size: 12))
                        .frame(height: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(AppTheme.Colors.divider, lineWidth: 1)
                        )
                }

                Picker("Agent", selection: $agentID) {
                    Text("Default assistant").tag(UUID?.none)
                    ForEach(dataStore.agents) { agent in
                        Text("\(agent.emoji) \(agent.name)").tag(Optional(agent.id))
                    }
                }

                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)

                Picker("Repeat", selection: $frequency) {
                    ForEach(ScheduledRun.Frequency.allCases, id: \.self) { frequency in
                        Text(frequency.displayName).tag(frequency)
                    }
                }
                .pickerStyle(.segmented)

                if frequency == .weekly {
                    Picker("On", selection: $weekday) {
                        ForEach(weekdayNames, id: \.number) { day in
                            Text(day.name).tag(day.number)
                        }
                    }
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 460)
    }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        var run = existing ?? ScheduledRun(name: name, prompt: prompt)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unnamed automation borrows its prompt's first line as a name.
        if trimmedName.isEmpty {
            let firstLine = trimmedPrompt.components(separatedBy: .newlines)[0]
            run.name = String(firstLine.prefix(40)) + (firstLine.count > 40 ? "…" : "")
        } else {
            run.name = trimmedName
        }
        run.prompt = trimmedPrompt
        run.agentID = agentID
        run.hour = components.hour ?? 9
        run.minute = components.minute ?? 0
        run.frequency = frequency
        run.weekday = frequency == .weekly ? weekday : nil
        onSave(run)
    }
}
