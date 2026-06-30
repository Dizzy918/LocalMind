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
    @AppStorage("embeddingProvider") private var embeddingProvider = "apple"
    @State private var importError: String?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            header
            toggleRow
            embedderRow
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
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppTheme.Colors.accentPrimary, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
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
                addDocuments()
            } label: {
                if store.isIndexing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Indexing…") }
                } else {
                    Label("Add documents…", systemImage: "plus")
                }
            }
            .disabled(store.isIndexing || !store.isAvailable)
        }
    }

    /// Picks the embedding backend (locked once documents exist). Ollama gives
    /// better retrieval; Apple is the always-available default.
    private var embedderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if store.isEmpty {
                    Text("Embedding")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $embeddingProvider) {
                        Text("On-device (Apple)").tag("apple")
                        Text("Ollama (nomic-embed-text)").tag("ollama")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 230)
                    Spacer()
                } else {
                    Text("Indexed with \(store.embedderLabel)")
                        .font(AppTheme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear all") { store.clear() }
                        .controlSize(.small)
                        .help("Remove all documents (needed to switch embedding model)")
                }
            }
            if store.isEmpty && embeddingProvider == "ollama" {
                Text("Needs Ollama running with the model pulled: `ollama pull nomic-embed-text`. Falls back to on-device if it's unavailable.")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private func addDocuments() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .text]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.title = "Add documents to your knowledge base"
        panel.message = "Pick files or a folder — subfolders are scanned for PDFs and text files."
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
        #endif
    }

    /// Imports a mix of files and folders. Folders are scanned recursively; each
    /// supported file is extracted and indexed, with a summary of any failures.
    private func importURLs(_ urls: [URL]) {
        importError = nil
        let files = Self.collectSupportedFiles(from: urls)
        guard !files.isEmpty else {
            importError = "No PDFs or text files found in that selection."
            return
        }
        Task {
            var failures: [String] = []
            var anyAdded = false
            for url in files {
                guard let text = Self.extractText(from: url),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      await store.addDocument(name: url.lastPathComponent, text: text) > 0 else {
                    failures.append(url.lastPathComponent)
                    continue
                }
                anyAdded = true
            }
            if anyAdded { useKnowledgeBase = true }
            if failures.isEmpty {
                importError = nil
            } else {
                let shown = failures.prefix(3).joined(separator: ", ")
                importError = "Couldn't index \(failures.count) file\(failures.count == 1 ? "" : "s"): \(shown)\(failures.count > 3 ? "…" : "")"
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let direct = item as? URL { url = direct }
                if let url { lock.lock(); collected.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !collected.isEmpty { importURLs(collected) }
        }
        return true
    }

    private static let supportedExtensions: Set<String> =
        ["pdf", "txt", "md", "markdown", "text", "csv", "tsv", "json", "log", "rtf"]

    /// Flattens a selection of files and folders into supported document URLs.
    static func collectSupportedFiles(from urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for case let file as URL in enumerator
                    where supportedExtensions.contains(file.pathExtension.lowercased()) {
                        result.append(file)
                    }
                }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
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
