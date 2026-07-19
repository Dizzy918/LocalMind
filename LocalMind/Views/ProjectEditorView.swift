//
//  ProjectEditorView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 14.07.26.
//

import SwiftUI

/// Create/edit sheet for a project — the workspace defaults every
/// conversation inside will inherit.
struct ProjectEditorView: View {
    let dataStore: DataStore
    let onSave: (Project) -> Void
    let onCancel: () -> Void

    private let existing: Project?

    @State private var name: String
    @State private var emoji: String
    @State private var agentID: UUID?
    @State private var systemPrompt: String
    @State private var restrictCollections: Bool
    @State private var selectedCollections: Set<String>

    init(
        project: Project?,
        dataStore: DataStore,
        onSave: @escaping (Project) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.existing = project
        self.dataStore = dataStore
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: project?.name ?? "")
        _emoji = State(initialValue: project?.emoji ?? "📁")
        _agentID = State(initialValue: project?.agentID)
        _systemPrompt = State(initialValue: project?.systemPrompt ?? "")
        _restrictCollections = State(initialValue: project?.knowledgeCollections != nil)
        _selectedCollections = State(initialValue: Set(project?.knowledgeCollections ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(existing == nil ? "New Project" : "Edit Project")
                    .font(AppTheme.Typography.title2)
                Text("Chats in a project inherit its agent, knowledge collections, and context — change them here and every chat inside follows.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                HStack(spacing: AppTheme.Spacing.sm) {
                    TextField("Emoji", text: $emoji)
                        .frame(width: 60)
                    TextField("Name", text: $name)
                }

                Picker("Default agent", selection: $agentID) {
                    Text("Default assistant").tag(UUID?.none)
                    ForEach(dataStore.agents) { agent in
                        Text("\(agent.emoji) \(agent.name)").tag(Optional(agent.id))
                    }
                }
                .help("Answers every chat in this project unless a chat picks its own agent")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Project context (added to every chat)")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 12))
                        .frame(height: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(AppTheme.Colors.divider, lineWidth: 1)
                        )
                }

                let collections = KnowledgeBaseStore.shared.collections
                if !collections.isEmpty {
                    Toggle("Limit knowledge to specific collections", isOn: $restrictCollections)
                    if restrictCollections {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(collections, id: \.self) { collection in
                                Toggle(collection, isOn: Binding(
                                    get: { selectedCollections.contains(collection) },
                                    set: { included in
                                        if included {
                                            selectedCollections.insert(collection)
                                        } else {
                                            selectedCollections.remove(collection)
                                        }
                                    }
                                ))
                                .font(AppTheme.Typography.caption)
                            }
                        }
                        .padding(.leading, AppTheme.Spacing.xl)
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 480)
    }

    private func save() {
        var project = existing ?? Project(name: name)
        project.name = name.trimmingCharacters(in: .whitespaces)
        project.emoji = emoji.isEmpty ? "📁" : String(emoji.prefix(2))
        project.agentID = agentID
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        project.systemPrompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt
        // An empty restriction would read as "no filter" downstream — the
        // opposite of what the toggle promises — so it falls back to nil (all).
        let collections = Array(selectedCollections).sorted()
        project.knowledgeCollections = (restrictCollections && !collections.isEmpty) ? collections : nil
        onSave(project)
    }
}
