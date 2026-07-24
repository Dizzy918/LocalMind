//
//  DataStore.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation
import Compression
import os

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
    private(set) var agents: [Agent] = []
    private(set) var promptSnippets: [PromptSnippet] = []
    private(set) var projects: [Project] = []
    private(set) var pipelines: [AgentPipeline] = []

    private let fileManager = FileManager.default
    let baseDirectory: URL

    /// Where profile scoping reads `activeProfileID`. Production uses
    /// `.standard`; tests inject an isolated suite so the profile filter can't
    /// be polluted by another parallel test process sharing `.standard`.
    let defaults: UserDefaults

    /// Persistence failures used to vanish into `try?` — a failed save meant
    /// silent data loss. They're at least visible in Console now.
    private static let logger = Logger(subsystem: "com.localmind.app", category: "DataStore")

    private static let compressionThreshold = 50_000 // 50KB
    private let pageSize = 20

    // Search index: conversation ID -> lowercased searchable text
    private var searchIndex: [UUID: String] = [:]

    // MARK: - Initialization

    init() {
        defaults = .standard
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldBaseDirectory = appSupport.appendingPathComponent("LocalAIHelper", isDirectory: true)
        baseDirectory = appSupport.appendingPathComponent("LocalMind", isDirectory: true)

        if fileManager.fileExists(atPath: oldBaseDirectory.path) && !fileManager.fileExists(atPath: baseDirectory.path) {
            do {
                try fileManager.moveItem(at: oldBaseDirectory, to: baseDirectory)
                Self.logger.info("Migrated data directory from LocalAIHelper to LocalMind")
            } catch {
                Self.logger.error("Failed to migrate data directory: \(error.localizedDescription, privacy: .public)")
            }
        }

        ensureDirectories()
        loadAll()
        buildSearchIndex()
        adoptOrphansForExistingProfile()
        seedDefaultAgentsIfNeeded()
    }

    /// Test-only initializer that lets the suite point at an isolated
    /// temp directory instead of the user's real Application Support
    /// folder. Production code MUST use `init()`; this overload exists
    /// only so XCTest can run without polluting the user's chat history.
    init(baseDirectoryOverride: URL, defaults: UserDefaults? = nil) {
        // Default each test store to its own throwaway suite so profile-scoping
        // reads are deterministic regardless of what another parallel test
        // process writes to `.standard`.
        self.defaults = defaults ?? UserDefaults(suiteName: "LocalMindTests-\(UUID().uuidString)") ?? .standard
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
        guard let raw = defaults.string(forKey: "activeProfileID"),
              let uuid = UUID(uuidString: raw) else { return }
        let hasOrphans = conversations.contains { $0.profileID == nil }
        guard hasOrphans else { return }
        claimOrphanConversations(forProfile: uuid)
    }

    // MARK: - Directory Management

    private func ensureDirectories() {
        let dirs = ["conversations", "focus_sessions", "custom_tools", "agents", "prompt_snippets", "projects", "pipelines"]
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

    private func decompressData(_ data: Data) -> Data? {
        // Start at a multiple of the compressed size and grow on demand.
        // A fixed 10MB buffer used to be allocated for every read (even tiny
        // files) — and, worse, anything that decompressed past 10MB was
        // silently unloadable.
        var bufferSize = max(data.count * 4, 64 * 1024)
        let hardCap = 512 * 1024 * 1024

        while bufferSize <= hardCap {
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { destinationBuffer.deallocate() }

            let decompressedSize = data.withUnsafeBytes { sourcePtr -> Int in
                guard let baseAddress = sourcePtr.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBuffer, bufferSize,
                    baseAddress.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB
                )
            }

            guard decompressedSize > 0 else { return nil }
            // A full buffer means the output was probably truncated — retry bigger.
            if decompressedSize == bufferSize {
                bufferSize *= 4
                continue
            }
            return Data(bytes: destinationBuffer, count: decompressedSize)
        }
        Self.logger.error("Decompression exceeded the \(hardCap)-byte cap; refusing to load")
        return nil
    }

    /// Writes with atomic semantics and logs failures instead of dropping them.
    private func writeOrLog(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeWithCompression(_ data: Data, to url: URL) {
        if data.count > Self.compressionThreshold, let compressed = compressData(data) {
            let compressedURL = url.deletingPathExtension().appendingPathExtension("json.gz")
            writeOrLog(compressed, to: compressedURL)
            // Remove uncompressed version if it exists
            try? fileManager.removeItem(at: url)
        } else {
            writeOrLog(data, to: url)
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
           let raw = defaults.string(forKey: "activeProfileID"),
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
            Self.logger.info("Migrated \(changed) orphan conversation(s) to the active profile")
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        searchIndex.removeValue(forKey: conversation.id)

        let url = conversationURL(for: conversation.id)
        try? fileManager.removeItem(at: url)
        let compressedURL = url.deletingPathExtension().appendingPathExtension("json.gz")
        try? fileManager.removeItem(at: compressedURL)

        // Deleting a chat must also delete what the memory index remembers of
        // it — otherwise "deleted" conversations would keep resurfacing.
        let deletedID = conversation.id
        Task { @MainActor in
            ChatMemoryStore.shared.forget(conversationID: deletedID)
        }
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
                    // Loose chats only — project conversations live under their project.
                    return $0.toolType == .chat && $0.customToolID == nil && $0.projectID == nil
                case .customTool(let id):
                    return $0.toolType == .chat && $0.customToolID == id
                case .project(let id):
                    return $0.projectID == id
                }
            }
            .sorted { lhs, rhs in
                // Pinned conversations always sort first; within each group, sort by updatedAt.
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    /// Every conversation the active profile can see, newest first, regardless
    /// of which tool or project it belongs to.
    ///
    /// `conversationsForSelection` deliberately scopes to one sidebar section;
    /// the tab layout needs the flat list — a tab strip spans projects and
    /// tools, and so do its history menu and tab picker.
    func conversationsForActiveProfile(includeArchived: Bool = false) -> [Conversation] {
        let activeID = activeProfileID()
        return conversations
            .filter { !$0.messages.isEmpty }
            .filter { includeArchived || !$0.isArchived }
            .filter { convo in
                if let active = activeID {
                    return convo.profileID == active
                } else {
                    return convo.profileID == nil
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func activeProfileID() -> UUID? {
        guard let raw = defaults.string(forKey: "activeProfileID") else { return nil }
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
                    return $0.toolType == .chat && $0.customToolID == nil && $0.projectID == nil
                case .customTool(let id):
                    return $0.toolType == .chat && $0.customToolID == id
                case .project(let id):
                    return $0.projectID == id
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Merges `source` into `target`, then deletes source. The combined
    /// message list is ordered by timestamp so the merged history reads
    /// chronologically even when the source conversation is the older one.
    /// (Swift's sort is stable, so same-timestamp messages keep their order.)
    func mergeConversation(_ source: Conversation, into target: Conversation) {
        guard source.id != target.id else { return }
        var merged = target
        merged.messages = (target.messages + source.messages).sorted { $0.timestamp < $1.timestamp }
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

        let activeID = activeProfileID()
        return conversations
            .filter { matchingIDs.contains($0.id) }
            // Search must stay within the active profile — otherwise profile A
            // could surface profile B's chats. Mirrors conversationsForSelection.
            .filter { convo in
                if let active = activeID {
                    return convo.profileID == active
                } else {
                    return convo.profileID == nil
                }
            }
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
            writeOrLog(data, to: url)
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
        agents = loadItems(from: "agents")
        agents.sort { $0.createdAt < $1.createdAt }
        promptSnippets = loadItems(from: "prompt_snippets")
        promptSnippets.sort { $0.createdAt < $1.createdAt }
        projects = loadItems(from: "projects")
        projects.sort { $0.createdAt < $1.createdAt }
        pipelines = loadItems(from: "pipelines")
        pipelines.sort { $0.createdAt < $1.createdAt }
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
            writeOrLog(data, to: url)
        }
    }

    func deleteCustomTool(_ tool: CustomTool) {
        customTools.removeAll { $0.id == tool.id }

        let url = baseDirectory
            .appendingPathComponent("custom_tools")
            .appendingPathComponent("\(tool.id).json")
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Agents

    func saveAgent(_ agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
        } else {
            agents.append(agent)
        }

        let url = agentURL(for: agent.id)
        if let data = try? JSONEncoder().encode(agent) {
            writeOrLog(data, to: url)
        }
    }

    func deleteAgent(_ agent: Agent) {
        agents.removeAll { $0.id == agent.id }
        try? fileManager.removeItem(at: agentURL(for: agent.id))
    }

    func agent(withID id: UUID?) -> Agent? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    private func agentURL(for id: UUID) -> URL {
        baseDirectory
            .appendingPathComponent("agents")
            .appendingPathComponent("\(id.uuidString).json")
    }

    /// All agents as a pretty-printed JSON array, for sharing.
    func exportAgentsData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(agents)
    }

    /// Imports agents from a JSON export (an array or a single agent).
    /// Agents whose ID already exists are updated in place — so re-importing
    /// an edited export round-trips — and everything else is added.
    /// Returns how many agents were added or updated.
    @discardableResult
    func importAgents(from data: Data) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var imported: [Agent] = []
        if let many = try? decoder.decode([Agent].self, from: data) {
            imported = many
        } else if let one = try? decoder.decode(Agent.self, from: data) {
            imported = [one]
        } else {
            // Fall back to the default date strategy so files produced by
            // JSONEncoder() without ISO dates also import.
            let plain = JSONDecoder()
            if let many = try? plain.decode([Agent].self, from: data) {
                imported = many
            } else if let one = try? plain.decode(Agent.self, from: data) {
                imported = [one]
            } else {
                return 0
            }
        }

        for agent in imported {
            saveAgent(agent)
        }
        return imported.count
    }

    // MARK: - Projects

    func saveProject(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        let url = baseDirectory
            .appendingPathComponent("projects")
            .appendingPathComponent("\(project.id.uuidString).json")
        if let data = try? JSONEncoder().encode(project) {
            writeOrLog(data, to: url)
        }
    }

    /// Deletes a project. Its conversations aren't deleted — they become
    /// loose conversations again (visible under Chat).
    func deleteProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        let url = baseDirectory
            .appendingPathComponent("projects")
            .appendingPathComponent("\(project.id.uuidString).json")
        try? fileManager.removeItem(at: url)

        for conversation in conversations where conversation.projectID == project.id {
            var freed = conversation
            freed.projectID = nil
            saveConversation(freed)
        }
    }

    func project(withID id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    // MARK: - Pipelines

    func savePipeline(_ pipeline: AgentPipeline) {
        if let index = pipelines.firstIndex(where: { $0.id == pipeline.id }) {
            pipelines[index] = pipeline
        } else {
            pipelines.append(pipeline)
        }
        let url = baseDirectory
            .appendingPathComponent("pipelines")
            .appendingPathComponent("\(pipeline.id.uuidString).json")
        if let data = try? JSONEncoder().encode(pipeline) {
            writeOrLog(data, to: url)
        }
    }

    func deletePipeline(_ pipeline: AgentPipeline) {
        pipelines.removeAll { $0.id == pipeline.id }
        let url = baseDirectory
            .appendingPathComponent("pipelines")
            .appendingPathComponent("\(pipeline.id.uuidString).json")
        try? fileManager.removeItem(at: url)
    }

    /// All pipelines as a pretty-printed JSON array, for sharing.
    func exportPipelinesData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(pipelines)
    }

    /// Imports pipelines from a JSON export (an array or a single pipeline).
    /// Same-ID pipelines are updated in place — re-importing an edited export
    /// round-trips — and everything else is added. Returns the count handled.
    /// Steps referencing agents that don't exist here still import; they just
    /// run with the default assistant until the agents are imported too.
    @discardableResult
    func importPipelines(from data: Data) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var imported: [AgentPipeline] = []
        if let many = try? decoder.decode([AgentPipeline].self, from: data) {
            imported = many
        } else if let one = try? decoder.decode(AgentPipeline.self, from: data) {
            imported = [one]
        } else {
            // Fall back to the default date strategy, mirroring importAgents.
            let plain = JSONDecoder()
            if let many = try? plain.decode([AgentPipeline].self, from: data) {
                imported = many
            } else if let one = try? plain.decode(AgentPipeline.self, from: data) {
                imported = [one]
            } else {
                return 0
            }
        }

        for pipeline in imported {
            savePipeline(pipeline)
        }
        return imported.count
    }

    // MARK: - Prompt Snippets

    func savePromptSnippet(_ snippet: PromptSnippet) {
        if let index = promptSnippets.firstIndex(where: { $0.id == snippet.id }) {
            promptSnippets[index] = snippet
        } else {
            promptSnippets.append(snippet)
        }
        let url = baseDirectory
            .appendingPathComponent("prompt_snippets")
            .appendingPathComponent("\(snippet.id.uuidString).json")
        if let data = try? JSONEncoder().encode(snippet) {
            writeOrLog(data, to: url)
        }
    }

    func deletePromptSnippet(_ snippet: PromptSnippet) {
        promptSnippets.removeAll { $0.id == snippet.id }
        let url = baseDirectory
            .appendingPathComponent("prompt_snippets")
            .appendingPathComponent("\(snippet.id.uuidString).json")
        try? fileManager.removeItem(at: url)
    }

    /// Seeds the starter personas exactly once, so the Agents feature isn't an
    /// empty list on first discovery. The one-shot flag (not the list being
    /// empty) is the guard: a user who deletes every agent shouldn't have the
    /// defaults resurrect on next launch. Only called from the production
    /// initializer — tests get a clean, unseeded store.
    private func seedDefaultAgentsIfNeeded() {
        let seedFlag = "didSeedDefaultAgents"
        guard !defaults.bool(forKey: seedFlag), agents.isEmpty else { return }
        for template in Agent.starterTemplates() {
            saveAgent(template)
        }
        defaults.set(true, forKey: seedFlag)
    }
}
