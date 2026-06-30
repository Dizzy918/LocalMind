//
//  MCPCatalog.swift
//  LocalMind
//
//  Curated list of well-known MCP servers — one-click install from
//  Settings → MCP Servers, mirroring how Claude Desktop ships presets.
//

import Foundation

struct MCPCatalogEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let iconSystemName: String
    let category: Category
    let officialURL: String?
    /// Default config; user may need to edit a value (e.g. allowed paths).
    let template: MCPServerConfig
    /// Free-form note shown before install (e.g. "needs an API key").
    let setupHint: String?

    enum Category: String, CaseIterable, Sendable {
        case files = "Files & Storage"
        case dev = "Development"
        case web = "Web & Search"
        case productivity = "Productivity"
        case memory = "Memory & Context"
        case custom = "Custom"
    }
}

enum MCPCatalog {
    /// Curated list of MCP servers. All are stdio-launched via npx so no
    /// separate install step is needed — Node.js + npm is the only prerequisite.
    static let all: [MCPCatalogEntry] = [
        MCPCatalogEntry(
            id: "filesystem",
            name: "Filesystem",
            description: "Read, write, and search files in folders you allow.",
            iconSystemName: "folder.fill",
            category: .files,
            officialURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem",
            template: MCPServerConfig(
                name: "Filesystem",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@modelcontextprotocol/server-filesystem", FileManager.default.homeDirectoryForCurrentUser.path],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Defaults to your home folder. Edit the path argument to restrict access."
        ),
        MCPCatalogEntry(
            id: "git",
            name: "Git",
            description: "Browse commits, branches, and diffs in any Git repository.",
            iconSystemName: "arrow.triangle.branch",
            category: .dev,
            officialURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/git",
            // Upstream moved Git off npm and ships only via Python now —
            // uvx (from astral.sh/uv) handles install-on-first-run.
            template: MCPServerConfig(
                name: "Git",
                transport: .stdio(
                    command: "uvx",
                    args: ["mcp-server-git"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Requires `uv` (install with: brew install uv)."
        ),
        MCPCatalogEntry(
            id: "memory",
            name: "Memory",
            description: "Persistent knowledge graph the AI can read and update across conversations.",
            iconSystemName: "brain",
            category: .memory,
            officialURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/memory",
            template: MCPServerConfig(
                name: "Memory",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@modelcontextprotocol/server-memory"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: nil
        ),
        MCPCatalogEntry(
            id: "fetch",
            name: "Web Fetch",
            description: "Lets the AI download and read web pages on demand.",
            iconSystemName: "globe",
            category: .web,
            officialURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch",
            template: MCPServerConfig(
                name: "Web Fetch",
                transport: .stdio(
                    command: "uvx",
                    args: ["mcp-server-fetch"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Requires `uv` (install with: brew install uv)."
        ),
        MCPCatalogEntry(
            id: "brave-search",
            name: "Brave Search",
            description: "Search the web via Brave's API.",
            iconSystemName: "magnifyingglass",
            category: .web,
            officialURL: "https://github.com/brave/brave-search-mcp-server",
            // Brave moved the server off @modelcontextprotocol (that package is
            // now deprecated on npm) to their own, actively-maintained package.
            template: MCPServerConfig(
                name: "Brave Search",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@brave/brave-search-mcp-server"],
                    env: ["BRAVE_API_KEY": ""]
                ),
                enabled: true
            ),
            setupHint: "Requires a Brave Search API key — fill BRAVE_API_KEY after install."
        ),
        MCPCatalogEntry(
            id: "github",
            name: "GitHub",
            description: "Read repositories, issues, and pull requests on github.com.",
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            category: .dev,
            officialURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/github",
            template: MCPServerConfig(
                name: "GitHub",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@modelcontextprotocol/server-github"],
                    env: ["GITHUB_PERSONAL_ACCESS_TOKEN": ""]
                ),
                enabled: true
            ),
            setupHint: "Requires a GitHub personal access token — fill GITHUB_PERSONAL_ACCESS_TOKEN."
        ),
        MCPCatalogEntry(
            id: "sqlite",
            name: "SQLite",
            description: "Query and inspect any local SQLite database.",
            iconSystemName: "cylinder.split.1x2",
            category: .files,
            officialURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/sqlite",
            template: MCPServerConfig(
                name: "SQLite",
                transport: .stdio(
                    command: "uvx",
                    args: ["mcp-server-sqlite", "--db-path", FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/LocalMind/notes.sqlite"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Requires `uv` (install with: brew install uv). Edit the path argument to point at your database file."
        ),
        MCPCatalogEntry(
            id: "apple-notes",
            name: "Apple Notes",
            description: "Search and create notes in Apple Notes.",
            iconSystemName: "note.text",
            category: .productivity,
            officialURL: nil,
            template: MCPServerConfig(
                name: "Apple Notes",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "apple-notes-mcp"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Community server — requires AppleScript permission on first run."
        )
    ]

    static func entries(in category: MCPCatalogEntry.Category) -> [MCPCatalogEntry] {
        all.filter { $0.category == category }
    }
}
