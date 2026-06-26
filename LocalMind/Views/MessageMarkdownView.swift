//
//  MessageMarkdownView.swift
//  LocalMind
//

import SwiftUI
import AppKit

enum MarkdownBlock: Hashable {
    case text(String)
    case code(language: String, code: String)
}

struct MessageMarkdownView: View {
    let text: String
    
    private var blocks: [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        let components = text.components(separatedBy: "```")
        
        for (index, component) in components.enumerated() {
            if index % 2 == 0 {
                // Text block
                let t = component.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    result.append(.text(t))
                }
            } else {
                // Code block
                let lines = component.components(separatedBy: .newlines)
                if let firstLine = lines.first {
                    let language = firstLine.trimmingCharacters(in: .whitespaces)
                    let code = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    result.append(.code(language: language, code: code))
                } else {
                    result.append(.code(language: "", code: component.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
        return result
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text(let t):
                    Text(LocalizedStringKey(t))
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                }
            }
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    
    @State private var didCopy = false
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                // Copy button
                Button(action: copyToClipboard) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(didCopy ? .green : .secondary)
                        .padding(4)
                        .background(isHovering ? Color.white.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .onHover { hover in
                    isHovering = hover
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(Color.black.opacity(0.4))
            
            // Code
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(AppTheme.Spacing.md)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.opacity(0.2))
        .cornerRadius(AppTheme.Dimensions.cornerRadiusSmall)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
    }
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        
        withAnimation { didCopy = true }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { didCopy = false }
        }
    }
}
