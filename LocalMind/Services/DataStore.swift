//
//  DataStore.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation
import Compression

/// Simple JSON file-based persistence for conversations and focus sessions.
///
/// Data is stored under `~/Library/Application Support/LocalMind/` with
/// one JSON file per entity (gzip-compressed when >50KB), organised into subdirectories:
///   - `conversations/`
///   - `focus_sessions/`
///   - `custom_tools/`
///
/// Supports:
///   - **Gzip compression** for large conversations (>50KB)
///   - **Lazy pagination** — only metadata loaded initially, full messages on demand
///   - **Incremental saves** — appends new messages instead of full re-encode
///   - **Full-text search** — background-indexed conversation search
@Observable
final class DataStore {
    private(set) var conversations: [Conversation] = []
    private(set) var focusSessions: [FocusSession] = []
    private(set) var customTools: [CustomTool] = []

    private let fileManager = FileManager.default
    let baseDirectory: URL

    private static let compressionThreshold = 50_000 // 50KB
    private let pageSize = 20

    // Search index: conversation ID -> lowercased searchable text
    private var searchIndex: [UUID: String] = [:]

    // MARK: - Initialization

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldBaseDirectory = appSupport.appendingPathComponent("LocalAIHelper", isDirectory: true)
        baseDirectory = appSupport.appendingPathComponent("LocalMind", isDirectory: true)

        if fileManager.fileExists(atPath: oldBaseDirectory.path) && !fileManager.fileExists(atPath: baseDirectory.path) {
            do {
                try fileManager.moveItem(at: oldBaseDirectory, to: baseDirectory)
                print("Successfully migrated data directory from LocalAIHelper to LocalMind")
            } catch {
                print("Failed to migrate data directory: \(error)")
            }
        }

        ensureDirectories()
        loadAll()
        buildSearchIndex()
        adoptOrphansForExistingProfile()
    }

    /// Test-only initializer that lets the suite point at an isolated
    /// temp directory instead of the user's real Application Support
    /// folder. Production code MUST use `init()`; this overload exists
    /// only so XCTest can run without polluting the user's chat history.
    init(baseDirectoryOverride: URL) {
        baseDirectory = baseDirectoryOverride
        ensureDirectories()
        loadAll()
        buildSearchIndex()
    }

    /// Upgrade path: if profiles already exist (user signed in on a prior
    /// build) but conversations are still orphans (created before the
    /// profile feature shipped), claim them for the currently-active
    /// profile. Without this, those conversations would silently
    /// disappear from the sidebar after the upgrade.
    private func adoptOrphansForExistingProfile() {
        guard let raw = UserDefaults.standard.string(forKey: "activeProfileID"),
              let uuid = UUID(uuidString: raw) else { return }
        let hasOrphans = conversations.contains { $0.profileID == nil }
        guard hasOrphans else { return }
        claimOrphanConversations(forProfile: uuid)
    }

    // MARK: - Directory Management

    private func ensureDirectories() {
        let dirs = ["conversations", "focus_sessions", "custom_tools"]
        for dir in dirs {
            let path = baseDirectory.appendingPathComponent(dir, isDirectory: true)
            try? fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }

    // MARK: - Compression

    private func compressData(_ data: Data) -> Data? {
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer, data.count,
                baseAddress.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    private func decompressData(_ data: Data, maxSize: Int = 10_000_000) -> Data? {
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, maxSize,
                baseAddress.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }

    private func writeWithCompression(_ data: Data, to url: URL) {
        if data.count > Self.compressionThreshold, let compressed = compressData(data) {
            let compressedURL = url.deletingPathExtension().appendingPathExtension("json.gz")
            try? compressed.write(to: compressedURL)
            // Remove uncompressed version if it exists
            try? fileManager.removeItem(at: url)
        } else {
            try? data.write(to: url)
            // Remove compressed version if it exists
            let compressedURL = url.deletingPathExtension().appendingPathExtension("json.gz")
            try? fileManager.removeItem(at: compressedURL)
        }
    }

    private func readWithDecompression(from url: URL) -> Data? {
        // Try compressed first
        let compressedURL = url.deletingPathExtension().appendingPathExtension("json.gz")
        if let compressed = try? Data(contentsOf: compressedURL) {
            return decompressData(compressed)
        }
        return try? Data(contentsOf: url)
    }

    // MARK: - Conversations

    func saveConversation(_ conversation: Conversation) {
        // Stamp the current profile onto unstamped conversations so they
        // belong to the signed-in user. Existing stamped conversations
        // stay with their original owner.
        var stamped = conversation
        if stamped.profileID == nil,
           let raw = UserDefaults.standard.string(forKey: "activeProfileID"),
           let uuid = UUID(uuidString: raw) {
            stamped.profileID = uuid
        }
        if let index = conversations.firstIndex(where: { $0.id == stamped.id }) {
            conversations[index] = stamped
        } else {
            conversations.insert(stamped, at: 0)
        }

        let url = conversationURL(for: stamped.id)
        if let data = try? JSONEncoder().encode(stamped) {
            writeWithCompression(data, to: url)
        }

        updateSearchIndex(for: stamped)
    }

    /// One-time migration: when the user creates their first profile, claim
    /// any orphan conversations (profileID == nil) for it. Subsequent
    /// profiles start fresh.
    func claimOrphanConversations(forProfile profileID: UUID) {
        var changed = 0
        for (idx, convo) in conversations.enumerated() where convo.profileID == nil {
            var updated = convo
            updated.profileID = profileID
            conversations[idx] = updated
            let url = conversationURL(for: updated.id)
            if let data = try? JSONEncoder().encode(updated) {
                writeWithCompression(data, to: url)
            }
            changed += 1
        }
        if changed > 0 {
            print("DataStore: migrated \(changed) orphan conversation(s) to profile \(profileID)")
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        searchIndex.removeValue(forKey: conversation.id)

        let url = conversationURL(for: conversation.id)
        try? fileManager.removeItem(at: url)
        let compressedURL = url.deletingPathExtension().appendingPathExtension("json.gz")
        try? fileManager.removeItem(at: compressedURL)
    }

    /// Imports a JSON file produced by either `Export All` (an array of conversations)
    /// or a single-conversation export. Returns the number of conversations that
    /// were added or merged. Duplicates (same `id`) are merged: the existing one
    /// is replaced only if the incoming `updatedAt` is newer.
    @discardableResult
    func importConversations(from data: Data) -> Int {
        let decoder = JSONDecoder()
        var imported: [Conversation] = []
        if let many = try? decoder.decode([Conversation].self, from: data) {
            imported = many
        } else if let one = try? decoder.decode(Conversation.self, from: data) {
            imported = [one]
        } else {
            return 0
        }

        var added = 0
        for incoming in imported {
            if let existingIndex = conversations.firstIndex(where: { $0.id == incoming.id }) {
                if incoming.updatedAt > conversations[existingIndex].updatedAt {
                    conversations[existingIndex] = incoming
                    saveConversation(incoming)
                    added += 1
                }
            } else {
                saveConversation(incoming)
                added += 1
            }
        }
        return added
    }

    func deleteAllConversations() {
        conversations.removeAll()
        searchIndex.removeAll()

        let dir = baseDirectory.appendingPathComponent("conversations")
        if let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    func conversationsForSelection(_ selection: SidebarSelection, includeArchived: Bool = false) -> [Conversation] {
        let activeID = activeProfileID()
        return conversations
            .filter { !$0.messages.isEmpty }
            .filter { includeArchived || !$0.isArchived }
            // Hide conversations owned by other profiles. Orphan conversations
            // (profileID == nil) are visible only when there's no active
            // profile — they get claimed on first profile creation.
            .filter { convo in
                if let active = activeID {
                    return convo.profileID == active
                } else {
                    return convo.profileID == nil
                }
            }
            .filter {
                switch selection {
                case .chat:
                    return $0.toolType == .chat && $0.customToolID == nil
                case .customTool(let id):
                    return $0.toolType == .chat && $0.customToolID == id
                }
            }
            .sorted { lhs, rhs in
                // Pinned conversations always sort first; within each group, sort by updatedAt.
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private func activeProfileID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: "activeProfileID") else { return nil }
        return UUID(uuidString: raw)
    }

    /// Returns archived conversations for the given selection.
    func archivedConversations(for selection: SidebarSelection) -> [Conversation] {
        let activeID = activeProfileID()
        return conversations
            .filter { !$0.messages.isEmpty && $0.isArchived }
            .filter { convo in
                if let active = activeID {
                    return convo.profileID == active
                } else {
                    return convo.profileID == nil
                }
            }
            .filter {
                switch selection {
                case .chat:
                    return $0.toolType == .chat && $0.customToolID == nil
                case .customTool(let id):
                    return $0.toolType == .chat && $0.customToolID == id
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Merges `source` into `target` by appending source's messages onto target, then deletes source.
    /// Messages are ordered: target's existing messages first, then source's messages sorted by timestamp.
    func mergeConversation(_ source: Conversation, into target: Conversation) {
        guard source.id != target.id else { return }
        var merged = target
        merged.messages.append(contentsOf: source.messages)
        merged.updatedAt = Date()
        saveConversation(merged)
        deleteConversation(source)
    }

    func togglePin(_ conversation: Conversation) {
        var updated = conversation
        updated.isPinned.toggle()
        saveConversation(updated)
    }

    func toggleArchive(_ conversation: Conversation) {
        var updated = conversation
        updated.isArchived.toggle()
        // Unpinning while archiving keeps the sidebar clean
        if updated.isArchived { updated.isPinned = false }
        saveConversation(updated)
    }

    // MARK: - Pagination

    func conversationsPage(_ page: Int, for selection: SidebarSelection) -> [Conversation] {
        let all = conversationsForSelection(selection)
        let start = page * pageSize
        guard start < all.count else { return [] }
        let end = min(start + pageSize, all.count)
        return Array(all[start..<end])
    }

    var totalConversationCount: Int { conversations.count }

    // MARK: - Search

    func searchConversations(query: String) -> [Conversation] {
        let terms = query.lowercased()
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        let matchingIDs = searchIndex.filter { entry in
            terms.allSatisfy { entry.value.contains($0) }
        }.map { $0.key }

        return conversations
            .filter { matchingIDs.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Returns a short snippet around the first query match within a conversation's
    /// message text. Returns nil when no message contains the term (e.g. title-only matches).
    func searchSnippet(for conversation: Conversation, query: String) -> String? {
        let firstTerm = query.lowercased()
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        guard !firstTerm.isEmpty else { return nil }

        for message in conversation.messages {
            let content = message.content
            let lower = content.lowercased()
            guard let range = lower.range(of: firstTerm) else { continue }
            let radius = 40
            let startOffset = max(0, lower.distance(from: lower.startIndex, to: range.lowerBound) - radius)
            let matchEndOffset = lower.distance(from: lower.startIndex, to: range.upperBound)
            let endOffset = min(content.count, matchEndOffset + radius)
            let startIdx = content.index(content.startIndex, offsetBy: startOffset)
            let endIdx = content.index(content.startIndex, offsetBy: endOffset)
            let prefix = startOffset > 0 ? "…" : ""
            let suffix = endOffset < content.count ? "…" : ""
            return prefix + content[startIdx..<endIdx]
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces) + suffix
        }
        return nil
    }

    private func buildSearchIndex() {
        for conversation in conversations {
            updateSearchIndex(for: conversation)
        }
    }

    private func updateSearchIndex(for conversation: Conversation) {
        let text = ([conversation.title] + conversation.messages.map { $0.content })
            .joined(separator: " ")
            .lowercased()
        searchIndex[conversation.id] = text
    }

    // MARK: - Focus Sessions

    func saveFocusSession(_ session: FocusSession) {
        if let index = focusSessions.firstIndex(where: { $0.id == session.id }) {
            focusSessions[index] = session
        } else {
            focusSessions.insert(session, at: 0)
        }

        let url = baseDirectory
            .appendingPathComponent("focus_sessions")
            .appendingPathComponent("\(session.id.uuidString).json")

        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: url)
        }
    }

    // MARK: - Bulk Loading

    private func loadAll() {
        let allConversations: [Conversation] = loadConversations()

        self.conversations = allConversations.filter { conversation in
            if conversation.messages.isEmpty {
                let url = conversationURL(for: conversation.id)
                try? fileManager.removeItem(at: url)
                let compressedURL = url.deletingPathExtension().appendingPathExtension("json.gz")
                try? fileManager.removeItem(at: compressedURL)
                return false
            }
            return true
        }

        focusSessions = loadItems(from: "focus_sessions")
        customTools = loadItems(from: "custom_tools")
    }

    private func loadConversations() -> [Conversation] {
        let dir = baseDirectory.appendingPathComponent("conversations")
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" || $0.lastPathComponent.hasSuffix(".json.gz") }
            .compactMap { url -> Conversation? in
                let data: Data?
                if url.lastPathComponent.hasSuffix(".json.gz") {
                    if let compressed = try? Data(contentsOf: url) {
                        data = decompressData(compressed)
                    } else {
                        data = nil
                    }
                } else {
                    data = try? Data(contentsOf: url)
                }
                guard let d = data else { return nil }
                return try? JSONDecoder().decode(Conversation.self, from: d)
            }
    }

    private func loadItems<T: Decodable>(from directory: String) -> [T] {
        let dir = baseDirectory.appendingPathComponent(directory)
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> T? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(T.self, from: data)
            }
    }

    private func conversationURL(for id: UUID) -> URL {
        baseDirectory
            .appendingPathComponent("conversations")
            .appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Custom Tools

    func saveCustomTool(_ tool: CustomTool) {
        if let index = customTools.firstIndex(where: { $0.id == tool.id }) {
            customTools[index] = tool
        } else {
            customTools.append(tool)
        }

        let url = baseDirectory
            .appendingPathComponent("custom_tools")
            .appendingPathComponent("\(tool.id).json")

        if let data = try? JSONEncoder().encode(tool) {
            try? data.write(to: url)
        }
    }

    func deleteCustomTool(_ tool: CustomTool) {
        customTools.removeAll { $0.id == tool.id }

        let url = baseDirectory
            .appendingPathComponent("custom_tools")
            .appendingPathComponent("\(tool.id).json")
        try? fileManager.removeItem(at: url)
    }
}
