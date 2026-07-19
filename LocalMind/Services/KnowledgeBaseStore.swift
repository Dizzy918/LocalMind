//
//  KnowledgeBaseStore.swift
//  LocalMind
//
//  Local, on-device document store for retrieval-augmented chat. Documents are
//  chunked and embedded with EmbeddingService; queries retrieve the nearest
//  chunks by cosine similarity. Documents can be grouped into named
//  collections (agents can subscribe to specific ones), and whole folders can
//  be watched so their files stay indexed automatically. Everything stays in
//  ~/Library/Application Support/LocalMind/knowledge.json — nothing leaves the
//  machine, in keeping with LocalMind's privacy promise.
//

import Foundation
import CoreServices
#if os(macOS)
import PDFKit
import Vision
import AppKit
#endif

struct KnowledgeChunk: Codable, Identifiable, Sendable {
    let id: UUID
    let documentID: UUID
    let text: String
    let embedding: [Double]
}

struct KnowledgeDocument: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let addedAt: Date
    var chunkCount: Int
    /// Named collection this document belongs to; nil = uncategorised.
    var collection: String?
    /// Absolute file path for documents imported from a watched folder, so
    /// syncing can detect changed or deleted files. nil = manual import.
    var sourcePath: String?
    /// The source file's modification date at index time.
    var fileModifiedAt: Date?
}

/// A retrieval result paired with its source document name (for citations).
struct KnowledgeHit: Sendable {
    let documentName: String
    let text: String
    let score: Double
}

private struct KnowledgeArchive: Codable {
    var documents: [KnowledgeDocument]
    var chunks: [KnowledgeChunk]
    var embedderID: String?
    var watchedFolders: [String]?
}

// MARK: - Document Importing

/// File collection + text extraction shared by manual imports and
/// watched-folder syncing. Handles plain text, PDFs (with on-device OCR
/// fallback for scans), Word/EPUB archives, HTML, RTF, images (OCR), and
/// common source-code files.
///
/// `nonisolated` opts out of the module's MainActor default so extraction can
/// run on a background thread — OCRing a 50-page scan or waiting on `unzip`
/// would beachball the app from the main actor.
nonisolated enum DocumentImporter {
    static let supportedExtensions: Set<String> = [
        // Plain text & data
        "txt", "md", "markdown", "text", "csv", "tsv", "json", "log",
        // Documents
        "pdf", "rtf", "docx", "epub", "html", "htm", "xml",
        // Images (indexed via on-device OCR)
        "png", "jpg", "jpeg", "heic", "tiff", "webp", "bmp",
        // Source code
        "swift", "py", "js", "ts", "tsx", "jsx", "java", "c", "cpp", "h", "hpp",
        "rb", "go", "rs", "kt", "sh", "zsh", "yaml", "yml", "toml", "css", "scss", "php", "sql"
    ]

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

    /// `extractText` on a background thread. Import paths run on the main
    /// actor (the store is UI state), but OCR and archive expansion are far
    /// too slow to do there — this is the variant they should call.
    static func extractTextInBackground(from url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            extractText(from: url)
        }.value
    }

    static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        #if os(macOS)
        switch ext {
        case "pdf":
            guard let document = PDFDocument(url: url) else { return nil }
            let native = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
            // Almost no embedded text in a multi-page PDF = a scan. Fall back
            // to on-device OCR so scanned documents index like real ones.
            if native.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32 {
                return native
            }
            return ocrPDF(document) ?? (native.isEmpty ? nil : native)

        case "png", "jpg", "jpeg", "heic", "tiff", "webp", "bmp":
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return ocrText(from: cgImage)

        case "docx":
            // .docx is a zip; the text lives in word/document.xml.
            guard let xml = unzippedContents(of: url, matching: { $0.hasSuffix("word/document.xml") })?.first else { return nil }
            return strippingMarkup(xml, paragraphBreaks: ["</w:p>"])

        case "epub":
            // .epub is a zip of (x)html chapters.
            let chapters = unzippedContents(of: url, matching: {
                $0.hasSuffix(".xhtml") || $0.hasSuffix(".html") || $0.hasSuffix(".htm")
            }) ?? []
            let text = chapters
                .compactMap { strippingMarkup($0, paragraphBreaks: ["</p>", "</P>", "<br/>", "<br>"]) }
                .joined(separator: "\n\n")
            return text.isEmpty ? nil : text

        case "html", "htm":
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return strippingMarkup(raw, paragraphBreaks: ["</p>", "</P>", "<br/>", "<br>", "</div>", "</h1>", "</h2>", "</h3>", "</li>"])

        case "rtf":
            guard let data = try? Data(contentsOf: url),
                  let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
            return attributed.string

        default:
            return try? String(contentsOf: url, encoding: .utf8)
        }
        #else
        return try? String(contentsOf: url, encoding: .utf8)
        #endif
    }

    #if os(macOS)
    // MARK: OCR (on-device, Vision framework)

    private static func ocrText(from image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// OCRs a (scanned) PDF page by page, capped so a 1000-page scan can't
    /// stall an import for an hour.
    private static func ocrPDF(_ document: PDFDocument, maxPages: Int = 50) -> String? {
        var pages: [String] = []
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = CGSize(width: bounds.width * 2, height: bounds.height * 2)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            if let text = ocrText(from: cgImage) {
                pages.append(text)
            }
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }

    // MARK: Archive formats (.docx, .epub)

    /// Extracts a zip-based document with the system unzip and returns the
    /// contents of entries whose (lowercased) path matches, in path order.
    private static func unzippedContents(of url: URL, matching predicate: (String) -> Bool) -> [String]? {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localmind-unzip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", url.path, "-d", workDir.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let enumerator = FileManager.default.enumerator(at: workDir, includingPropertiesForKeys: nil) else { return nil }

        var matches: [URL] = []
        for case let file as URL in enumerator where predicate(file.path.lowercased()) {
            matches.append(file)
        }
        matches.sort { $0.path < $1.path }
        let contents = matches.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        return contents.isEmpty ? nil : contents
    }
    #endif

    /// Strips XML/HTML markup down to readable text: paragraph-ish closing
    /// tags become newlines, remaining tags are dropped, entities decoded,
    /// and whitespace collapsed.
    static func strippingMarkup(_ markup: String, paragraphBreaks: [String]) -> String? {
        var text = markup
        // Scripts and styles are noise, not content.
        text = text.replacingOccurrences(
            of: "(?is)<(script|style)[^>]*>.*?</\\1>",
            with: " ",
            options: .regularExpression
        )
        for tag in paragraphBreaks {
            text = text.replacingOccurrences(of: tag, with: tag + "\n")
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Folder Watching

/// Thin FSEvents wrapper: fires the callback (coalesced by the stream's
/// latency window) whenever anything inside the watched paths changes.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "LocalMind.FolderWatcher")
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func watch(paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0, // latency: batches rapid saves into one sync
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

// MARK: - Store

@Observable
@MainActor
final class KnowledgeBaseStore {
    static let shared = KnowledgeBaseStore()

    private(set) var documents: [KnowledgeDocument] = []
    /// True while a document is being chunked + embedded.
    private(set) var isIndexing = false
    /// True while a watched-folder sync pass is running.
    private(set) var isSyncing = false
    /// Folders whose supported files are auto-indexed and kept in sync.
    private(set) var watchedFolders: [String] = []
    /// The embedding provider this store was built with. Locked once the store
    /// has documents, since vectors from different models aren't comparable.
    private(set) var embedderID: String = "apple"

    private var chunks: [KnowledgeChunk] = []
    private let fileURL: URL
    private var watcher: FolderWatcher?

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("knowledge.json")
        load()
        startWatchingIfNeeded()
    }

    var isEmpty: Bool { documents.isEmpty }
    var totalChunks: Int { chunks.count }
    var isAvailable: Bool { EmbeddingService.isAvailable }

    /// All collection names in use, sorted. (Agents subscribe by name.)
    var collections: [String] {
        Array(Set(documents.compactMap(\.collection))).sorted()
    }

    /// Friendly name of the locked embedder, for the documents panel.
    var embedderLabel: String {
        embedderID.hasPrefix("ollama:") ? "Ollama (\(embedderID.dropFirst("ollama:".count)))" : "On-device (Apple)"
    }

    private func provider(forID id: String) -> EmbeddingProvider {
        if id.hasPrefix("ollama:") {
            return OllamaEmbeddingProvider(model: String(id.dropFirst("ollama:".count)))
        }
        return AppleEmbeddingProvider()
    }

    /// Which provider to embed with next: locked to the store's embedder once
    /// it has documents, otherwise the user's preference (falling back to Apple
    /// when Ollama isn't reachable). nil when none is usable right now.
    private func resolveProvider() async -> EmbeddingProvider? {
        if !documents.isEmpty {
            let locked = provider(forID: embedderID)
            return await locked.probe() ? locked : nil
        }
        if (UserDefaults.standard.string(forKey: "embeddingProvider") ?? "apple") == "ollama" {
            let ollama = OllamaEmbeddingProvider()
            if await ollama.probe() { return ollama }
        }
        let apple = AppleEmbeddingProvider()
        return await apple.probe() ? apple : nil
    }

    /// Chunks + embeds off the main actor, then commits the result. Returns the
    /// number of chunks indexed (0 if the text yielded no usable vectors).
    @discardableResult
    func addDocument(name: String, text: String, collection: String? = nil, sourcePath: String? = nil, fileModifiedAt: Date? = nil) async -> Int {
        isIndexing = true
        defer { isIndexing = false }

        guard let provider = await resolveProvider() else { return 0 }

        let documentID = UUID()
        var produced: [KnowledgeChunk] = []
        for piece in EmbeddingService.chunk(text) {
            guard let embedding = await provider.embed(piece) else { continue }
            produced.append(KnowledgeChunk(id: UUID(), documentID: documentID, text: piece, embedding: embedding))
        }
        guard !produced.isEmpty else { return 0 }

        // Lock the store to this embedder on the first successful document.
        if documents.isEmpty { embedderID = provider.id }
        documents.append(KnowledgeDocument(
            id: documentID, name: name, addedAt: Date(), chunkCount: produced.count,
            collection: collection, sourcePath: sourcePath, fileModifiedAt: fileModifiedAt
        ))
        chunks.append(contentsOf: produced)
        save()
        return produced.count
    }

    func removeDocument(_ document: KnowledgeDocument) {
        chunks.removeAll { $0.documentID == document.id }
        documents.removeAll { $0.id == document.id }
        save()
    }

    /// Moves a document into a collection (nil = uncategorised).
    func setCollection(_ collection: String?, for document: KnowledgeDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let trimmed = collection?.trimmingCharacters(in: .whitespacesAndNewlines)
        documents[index].collection = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    func clear() {
        chunks.removeAll()
        documents.removeAll()
        embedderID = "apple"   // free the lock so the store can adopt a new embedder
        save()
    }

    /// Top-`topK` chunks most similar to `query`, each paired with its source
    /// document for citations. `collections` narrows retrieval to those named
    /// collections (nil = every document). Embeds the query with the store's
    /// locked provider so the vectors are comparable.
    func retrieve(_ query: String, topK: Int = 4, threshold: Double = 0.15, collections: [String]? = nil) async -> [KnowledgeHit] {
        guard !chunks.isEmpty,
              let provider = await resolveProvider(),
              let queryVector = await provider.embed(query) else { return [] }

        var searchable = chunks
        if let collections, !collections.isEmpty {
            let allowedDocIDs = Set(documents.filter { doc in
                doc.collection.map { collections.contains($0) } ?? false
            }.map(\.id))
            searchable = chunks.filter { allowedDocIDs.contains($0.documentID) }
        }

        let names = Dictionary(documents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return searchable
            .map { (chunk: $0, score: EmbeddingService.cosineSimilarity(queryVector, $0.embedding)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { KnowledgeHit(documentName: names[$0.chunk.documentID] ?? "Document", text: $0.chunk.text, score: $0.score) }
    }

    // MARK: - Watched Folders

    /// Starts watching a folder: imports its supported files now (into a
    /// collection named after the folder) and keeps them in sync as files
    /// change on disk.
    func addWatchedFolder(_ url: URL) async {
        let path = url.path
        guard !watchedFolders.contains(path) else { return }
        watchedFolders.append(path)
        save()
        startWatchingIfNeeded()
        await syncWatchedFolders()
    }

    /// Stops watching a folder and removes the documents it contributed.
    func removeWatchedFolder(_ path: String) {
        watchedFolders.removeAll { $0 == path }
        for document in documents where document.sourcePath?.hasPrefix(path + "/") == true {
            chunks.removeAll { $0.documentID == document.id }
            documents.removeAll { $0.id == document.id }
        }
        save()
        startWatchingIfNeeded()
    }

    /// Reconciles the index with what's on disk: imports new files, re-imports
    /// changed ones, and drops documents whose source file disappeared.
    func syncWatchedFolders() async {
        guard !watchedFolders.isEmpty, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        for folder in watchedFolders {
            let folderURL = URL(fileURLWithPath: folder)
            let files = DocumentImporter.collectSupportedFiles(from: [folderURL])
            let livePaths = Set(files.map(\.path))

            // Files that vanished → remove their documents.
            for document in documents
            where document.sourcePath?.hasPrefix(folder + "/") == true
                && !livePaths.contains(document.sourcePath ?? "") {
                removeDocument(document)
            }

            let collection = folderURL.lastPathComponent
            for file in files {
                let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
                if let existing = documents.first(where: { $0.sourcePath == file.path }) {
                    guard let modified, let known = existing.fileModifiedAt, modified > known else { continue }
                    removeDocument(existing) // changed on disk → re-import below
                }
                guard let text = await DocumentImporter.extractTextInBackground(from: file),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                await addDocument(
                    name: file.lastPathComponent,
                    text: text,
                    collection: collection,
                    sourcePath: file.path,
                    fileModifiedAt: modified
                )
            }
        }
    }

    private func startWatchingIfNeeded() {
        if watcher == nil {
            watcher = FolderWatcher { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.syncWatchedFolders()
                }
            }
        }
        watcher?.watch(paths: watchedFolders)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder().decode(KnowledgeArchive.self, from: data) else { return }
        documents = archive.documents
        chunks = archive.chunks
        embedderID = archive.embedderID ?? "apple"
        watchedFolders = archive.watchedFolders ?? []
    }

    private func save() {
        let archive = KnowledgeArchive(documents: documents, chunks: chunks, embedderID: embedderID, watchedFolders: watchedFolders)
        if let data = try? JSONEncoder().encode(archive) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
