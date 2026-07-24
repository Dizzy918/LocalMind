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
    /// Outcome of the last rebuild, shown inline so a partial result is stated
    /// rather than looking like a clean success.
    @State private var rebuildSummary: String?
    // "New collection…" prompt state: which document it's for + the name field.
    @State private var collectionPromptDocument: KnowledgeDocument?
    @State private var newCollectionName = ""
    @State private var documentFilter = ""

    /// Documents shown in the list: filtered by the search field (name or
    /// collection, case-insensitive) and sorted newest-first so recent imports
    /// are visible without scrolling.
    private var visibleDocuments: [KnowledgeDocument] {
        let sorted = store.documents.sorted { $0.addedAt > $1.addedAt }
        let query = documentFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.lowercased().contains(query)
                || ($0.collection?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            header
            toggleRow
            embedderRow
            watchedFoldersRow
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
        .alert("New Collection", isPresented: Binding(
            get: { collectionPromptDocument != nil },
            set: { if !$0 { collectionPromptDocument = nil } }
        )) {
            TextField("Collection name", text: $newCollectionName)
            Button("Cancel", role: .cancel) { collectionPromptDocument = nil }
            Button("Create") {
                if let document = collectionPromptDocument {
                    store.setCollection(newCollectionName, for: document)
                }
                collectionPromptDocument = nil
            }
        } message: {
            Text("Group documents so agents can retrieve from just this set.")
        }
    }

    // MARK: - Watched Folders

    /// Folders whose files are auto-indexed and kept in sync via FSEvents.
    /// Each folder's documents land in a collection named after it.
    private var watchedFoldersRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(store.watchedFolders.isEmpty
                     ? "Watch a folder to keep its files indexed automatically"
                     : "Watched folders")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                if store.isSyncing {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if !store.watchedFolders.isEmpty {
                    Button("Sync now") {
                        Task { await store.syncWatchedFolders() }
                    }
                    .controlSize(.small)
                    .disabled(store.isSyncing)
                    .help("Re-scan watched folders for new, changed, or deleted files")
                }
                Button("Watch folder…") { pickWatchedFolder() }
                    .controlSize(.small)
                    .disabled(!store.isAvailable)
            }
            ForEach(store.watchedFolders, id: \.self) { folder in
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.accentPrimary)
                    Text(URL(fileURLWithPath: folder).lastPathComponent)
                        .font(AppTheme.Typography.captionSecondary)
                        .help(folder)
                    Spacer()
                    Button {
                        store.removeWatchedFolder(folder)
                    } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop watching and remove its documents")
                }
                .padding(.leading, AppTheme.Spacing.lg)
            }
        }
    }

    private func pickWatchedFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Watch a folder"
        panel.message = "Supported files in this folder are indexed now and kept in sync as they change."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await store.addWatchedFolder(url)
            useKnowledgeBase = true
        }
        #endif
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

    /// Whether the picked embedder differs from what the library was indexed
    /// with — which a rebuild (not a wipe) is now the way to resolve.
    private var needsEmbedderSwitch: Bool {
        !store.isEmpty && selectedEmbedderID != store.embedderID
    }

    /// The picker's selection as a store embedder id.
    private var selectedEmbedderID: String {
        embeddingProvider == "ollama" ? "ollama:nomic-embed-text" : "apple"
    }

    private func rebuild() {
        rebuildSummary = nil
        Task {
            let summary = await store.reindexAll(switchingTo: selectedEmbedderID)
            if summary.rebuilt == 0 && summary.failed == 0 {
                rebuildSummary = "Couldn't rebuild — the embedding model isn't available right now."
            } else if summary.failed > 0 {
                rebuildSummary = "Rebuilt \(summary.rebuilt) document(s) into \(summary.chunks) chunks. \(summary.failed) couldn't be rebuilt."
            } else {
                rebuildSummary = "Rebuilt \(summary.rebuilt) document(s) into \(summary.chunks) chunks."
            }
        }
    }

    /// Picks the embedding backend. Ollama gives better retrieval; Apple is the
    /// always-available default. Changing it on a non-empty library is a
    /// rebuild, not a wipe.
    private var embedderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
                .disabled(store.isIndexing)

                Spacer()

                if !store.isEmpty {
                    Button(needsEmbedderSwitch ? "Rebuild with selection" : "Rebuild index") {
                        rebuild()
                    }
                    .controlSize(.small)
                    .disabled(store.isIndexing)
                    .help(needsEmbedderSwitch
                          ? "Re-embed every document with the selected model — no need to delete anything"
                          : "Re-chunk and re-embed every document, picking up indexing improvements")

                    Button("Clear all") { store.clear() }
                        .controlSize(.small)
                        .disabled(store.isIndexing)
                        .help("Remove all documents")
                }
            }

            if !store.isEmpty {
                Text(needsEmbedderSwitch
                     ? "Currently indexed with \(store.embedderLabel). Rebuilding re-embeds your documents into the selected model — your library is kept."
                     : "Indexed with \(store.embedderLabel).")
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let rebuildSummary {
                Text(rebuildSummary)
                    .font(AppTheme.Typography.captionSecondary)
                    .foregroundStyle(.tertiary)
            }

            if embeddingProvider == "ollama" {
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
        VStack(spacing: AppTheme.Spacing.sm) {
            // Filter — with dozens of documents, scrolling stops scaling.
            if store.documents.count > 5 {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Filter by name or collection…", text: $documentFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !documentFilter.isEmpty {
                        Button {
                            documentFilter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(AppTheme.Colors.backgroundTertiary))
            }

            scrollableDocuments
        }
    }

    private var scrollableDocuments: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(visibleDocuments) { document in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(AppTheme.Colors.accentPrimary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(document.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                if let collection = document.collection {
                                    Text(collection)
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(AppTheme.Colors.accentPrimary.opacity(0.15)))
                                        .foregroundStyle(AppTheme.Colors.accentPrimary)
                                }
                                if document.sourcePath != nil {
                                    Image(systemName: "folder.badge.gearshape")
                                        .font(.system(size: 9))
                                        .foregroundStyle(AppTheme.Colors.textTertiary)
                                        .help("Synced from a watched folder")
                                }
                            }
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
                    .contextMenu {
                        Menu("Move to collection") {
                            ForEach(store.collections, id: \.self) { collection in
                                Button(collection) { store.setCollection(collection, for: document) }
                            }
                            if !store.collections.isEmpty { Divider() }
                            Button("New collection…") {
                                newCollectionName = ""
                                collectionPromptDocument = document
                            }
                            if document.collection != nil {
                                Divider()
                                Button("Remove from collection") { store.setCollection(nil, for: document) }
                            }
                        }
                    }
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
        let files = DocumentImporter.collectSupportedFiles(from: urls)
        guard !files.isEmpty else {
            importError = "No PDFs or text files found in that selection."
            return
        }
        Task {
            var failures: [String] = []
            var anyAdded = false
            for url in files {
                guard let text = await DocumentImporter.extractTextInBackground(from: url),
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

}
