//
//  CustomToolSettingsView.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 23.06.26.
//

import SwiftUI

struct CustomToolSettingsView: View {
    let dataStore: DataStore
    
    @State private var showingAddTool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Custom Tools")
                    .font(AppTheme.Typography.title2)
                Spacer()
                Button(action: { showingAddTool = true }) {
                    Label("Add Tool", systemImage: "plus")
                }
            }
            
            if dataStore.customTools.isEmpty {
                Text("No custom tools added yet. Create one to customize your AI's behavior.")
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.vertical, AppTheme.Spacing.lg)
            } else {
                List {
                    ForEach(dataStore.customTools) { tool in
                        HStack {
                            Image(systemName: tool.icon)
                                .frame(width: 24)
                            Text(tool.name)
                            Spacer()
                            Button("Delete", role: .destructive) {
                                dataStore.deleteCustomTool(tool)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Colors.accentRed)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.bordered)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .sheet(isPresented: $showingAddTool) {
            AddCustomToolView(dataStore: dataStore) {
                showingAddTool = false
            }
        }
    }
}

struct AddCustomToolView: View {
    let dataStore: DataStore
    let onDismiss: () -> Void
    
    @State private var name = ""
    @State private var icon = "hammer"
    @State private var systemPrompt = "You are a helpful assistant."
    
    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Text("New Custom Tool")
                .font(AppTheme.Typography.title2)
            
            Form {
                TextField("Tool Name", text: $name)
                
                TextField("SF Symbol Icon", text: $icon)
                    .help("Try 'hammer', 'brain', 'doc.text', etc.")
                
                TextEditor(text: $systemPrompt)
                    .frame(height: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(AppTheme.Colors.divider, lineWidth: 1)
                    )
                Text("System Prompt defines how the AI will behave for this tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            
            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Button("Save") {
                    let newTool = CustomTool(name: name, icon: icon, systemPrompt: systemPrompt)
                    dataStore.saveCustomTool(newTool)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || systemPrompt.isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 400)
    }
}
