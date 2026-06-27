//
//  MessageMarkdownView.swift
//  LocalMind
//

import SwiftUI
import AppKit

enum MarkdownBlock: Hashable {
    case text(String)
    case code(language: String, code: String)
    case image(source: String)
}

struct MessageMarkdownView: View {
    let text: String

    private var blocks: [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        let components = text.components(separatedBy: "```")

        for (index, component) in components.enumerated() {
            if index % 2 == 0 {
                let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                result.append(contentsOf: splitTextAndImages(trimmed))
            } else {
                let lines = component.components(separatedBy: .newlines)
                if let firstLine = lines.first {
                    let language = firstLine.trimmingCharacters(in: .whitespaces)
                    let code = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    result.append(.code(language: language, code: code))
                }
            }
        }
        return result
    }

    /// Splits a text run on `![alt](src)` image markers and returns alternating
    /// text and image blocks. The src can be an http(s) URL or a `data:` URI.
    private func splitTextAndImages(_ text: String) -> [MarkdownBlock] {
        let pattern = #"!\[[^\]]*\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(text)]
        }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(text)] }

        var blocks: [MarkdownBlock] = []
        var cursor = 0

        for match in matches {
            if match.range.location > cursor {
                let textRange = NSRange(location: cursor, length: match.range.location - cursor)
                let chunk = ns.substring(with: textRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { blocks.append(.text(chunk)) }
            }
            let src = ns.substring(with: match.range(at: 1))
            blocks.append(.image(source: src))
            cursor = match.range.location + match.range.length
        }

        if cursor < ns.length {
            let chunk = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { blocks.append(.text(chunk)) }
        }

        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t):
                    Text(LocalizedStringKey(t))
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                case .image(let source):
                    InlineImageView(source: source)
                }
            }
        }
    }
}

struct InlineImageView: View {
    let source: String

    var body: some View {
        if source.hasPrefix("data:") {
            if let image = decodeDataURI(source) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480)
                    .cornerRadius(AppTheme.Dimensions.cornerRadiusSmall)
            } else {
                Text("⚠️ Could not decode image")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
            }
        } else if let url = URL(string: source) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView().frame(maxWidth: 480, minHeight: 100)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 480)
                        .cornerRadius(AppTheme.Dimensions.cornerRadiusSmall)
                case .failure:
                    Text("⚠️ Failed to load image")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                @unknown default:
                    EmptyView()
                }
            }
        }
    }

    private func decodeDataURI(_ uri: String) -> NSImage? {
        guard let commaIdx = uri.firstIndex(of: ",") else { return nil }
        let base64Part = String(uri[uri.index(after: commaIdx)...])
        guard let data = Data(base64Encoded: base64Part) else { return nil }
        return NSImage(data: data)
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var didCopy = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: copyToClipboard) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(didCopy ? .green : .secondary)
                        .padding(4)
                        .background(isHovering ? Color.white.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(Color.black.opacity(0.4))

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
