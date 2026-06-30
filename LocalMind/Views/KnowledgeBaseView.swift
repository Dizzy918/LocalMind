//
//  KnowledgeBaseView.swift
//  LocalMind
//
//  Manage the on-device document store used for "chat with your documents".
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import PDFKit
#endif

struct KnowledgeBaseView: View {
    let store: KnowledgeBaseStore
    let onClose: () -> Void

    @AppStorage("useKnowledgeBase") private var useKnowledgeBase = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            header
            toggleRow
            Divider()

            if store.documents.isEmpty {
                emptyState
            } else {
                documentList
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.red)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 520, height: 480)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Documents")
                    .font(AppTheme.Typography.headline)
                Text("Add PDFs or text files; LocalMind pulls in the relevant parts when you chat. Everything is indexed and stored on-device.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var toggleRow: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Toggle(isOn: $useKnowledgeBase) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use my documents in chats")
                        .font(AppTheme.Typography.body)
                    Text(store.isEmpty
                         ? "Add a document to enable this."
                         : "\(store.documents.count) document\(store.documents.count == 1 ? "" : "s") · \(store.totalChunks) chunks indexed")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(store.isEmpty)

            Spacer()

            Button {
                addDocument()
            } label: {
                if store.isIndexing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Indexing…") }
                } else {
                    Label("Add document…", systemImage: "plus")
                }
            }
            .disabled(store.isIndexing || !store.isAvailable)
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "books.vertical")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(store.isAvailable ? "No documents yet." : "On-device embeddings aren't available on this Mac.")
                .font(AppTheme.Typography.body)
            if store.isAvailable {
                Text("Add a PDF or text file to start chatting with its contents.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var documentList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(store.documents) { document in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(AppTheme.Colors.accentPrimary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                            Text("\(document.chunkCount) chunks · added \(document.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(AppTheme.Typography.captionSecondary)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.removeDocument(document)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove document")
                    }
                    .padding(AppTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AppTheme.Colors.backgroundSecondary.opacity(0.5))
                    )
                }
            }
        }
    }

    private func addDocument() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Add a document to your knowledge base"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        importError = nil
        Task {
            guard let text = Self.extractText(from: url),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                importError = "Couldn't read any text from \(url.lastPathComponent)."
                return
            }
            let indexed = await store.addDocument(name: url.lastPathComponent, text: text)
            if indexed == 0 {
                importError = "No indexable text found in \(url.lastPathComponent)."
            } else {
                // Turning on retrieval automatically the first time a document
                // is added makes the feature actually do something.
                useKnowledgeBase = true
            }
        }
        #endif
    }

    static func extractText(from url: URL) -> String? {
        #if os(macOS)
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { return nil }
            return (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
        }
        #endif
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
