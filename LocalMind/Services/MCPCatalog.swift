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
        case communication = "Mail & Communication"
        case appleApps = "Apple Apps"
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
        ),
        MCPCatalogEntry(
            id: "duckduckgo",
            name: "DuckDuckGo Search",
            description: "Search the web — no API key needed.",
            iconSystemName: "magnifyingglass.circle",
            category: .web,
            officialURL: "https://github.com/nickclyde/duckduckgo-mcp-server",
            template: MCPServerConfig(
                name: "DuckDuckGo Search",
                transport: .stdio(
                    command: "uvx",
                    args: ["duckduckgo-mcp-server"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Requires `uv` (install with: brew install uv). Keyless — the easiest way to give the AI web search."
        ),
        MCPCatalogEntry(
            id: "playwright",
            name: "Browser (Playwright)",
            description: "Let the AI open, read, and interact with real web pages.",
            iconSystemName: "network",
            category: .web,
            officialURL: "https://github.com/microsoft/playwright-mcp",
            template: MCPServerConfig(
                name: "Browser",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@playwright/mcp@latest"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Microsoft's official browser-automation server. Downloads a browser on first run (~150 MB)."
        ),
        MCPCatalogEntry(
            id: "time",
            name: "Time",
            description: "Current time and timezone conversions — small models get these wrong surprisingly often.",
            iconSystemName: "clock",
            category: .productivity,
            officialURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/time",
            template: MCPServerConfig(
                name: "Time",
                transport: .stdio(
                    command: "uvx",
                    args: ["mcp-server-time"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Requires `uv` (install with: brew install uv)."
        ),
        MCPCatalogEntry(
            id: "sequential-thinking",
            name: "Sequential Thinking",
            description: "A structured scratchpad that walks the model through step-by-step reasoning — helps small local models on hard problems.",
            iconSystemName: "list.number",
            category: .memory,
            officialURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking",
            template: MCPServerConfig(
                name: "Sequential Thinking",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@modelcontextprotocol/server-sequential-thinking"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: nil
        ),
        MCPCatalogEntry(
            id: "obsidian",
            name: "Obsidian Vault",
            description: "Read and search the Markdown notes in an Obsidian vault (or any folder of .md files).",
            iconSystemName: "doc.text.magnifyingglass",
            category: .files,
            officialURL: "https://github.com/smithery-ai/mcp-obsidian",
            template: MCPServerConfig(
                name: "Obsidian Vault",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "mcp-obsidian", FileManager.default.homeDirectoryForCurrentUser.path + "/Documents"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Edit the path argument to point at your vault folder."
        ),
        MCPCatalogEntry(
            id: "youtube-transcript",
            name: "YouTube Transcripts",
            description: "Fetch a video's transcript so the AI can summarize or answer questions about it.",
            iconSystemName: "play.rectangle",
            category: .web,
            officialURL: "https://github.com/kimtaeyoon83/mcp-server-youtube-transcript",
            template: MCPServerConfig(
                name: "YouTube Transcripts",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@kimtaeyoon83/mcp-server-youtube-transcript"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Community server. Only works for videos that have captions."
        ),
        MCPCatalogEntry(
            id: "postgres",
            name: "PostgreSQL",
            description: "Run read-only queries against a Postgres database and inspect its schema.",
            iconSystemName: "cylinder.split.1x2.fill",
            category: .dev,
            officialURL: "https://github.com/modelcontextprotocol/servers-archived/tree/main/src/postgres",
            template: MCPServerConfig(
                name: "PostgreSQL",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/postgres"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Edit the connection string argument for your database. Reference server (archived upstream, still functional)."
        ),
        MCPCatalogEntry(
            id: "applescript",
            name: "AppleScript",
            description: "Let the AI control Mac apps via AppleScript — calendars, Finder, Music, and more.",
            iconSystemName: "applescript",
            category: .appleApps,
            officialURL: "https://github.com/joshrutkowski/applescript-mcp",
            template: MCPServerConfig(
                name: "AppleScript",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "applescript-mcp"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Powerful — scripts can control your Mac. Keep per-call approval ON for this one."
        ),

        // MARK: Google

        MCPCatalogEntry(
            id: "gmail",
            name: "Gmail",
            description: "Search, read, draft, and send email in your Gmail account.",
            iconSystemName: "envelope.fill",
            category: .communication,
            officialURL: "https://github.com/GongRzhe/Gmail-MCP-Server",
            template: MCPServerConfig(
                name: "Gmail",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@gongrzhe/server-gmail-autoauth-mcp"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Needs a one-time Google OAuth setup: create a Google Cloud OAuth client, save it as ~/.gmail-mcp/gcp-oauth.keys.json, then run `npx @gongrzhe/server-gmail-autoauth-mcp auth` once in Terminal. Keep per-call approval ON — this server can send mail."
        ),
        MCPCatalogEntry(
            id: "google-calendar",
            name: "Google Calendar",
            description: "Check your schedule, find free slots, and create events.",
            iconSystemName: "calendar",
            category: .productivity,
            officialURL: "https://github.com/nspady/google-calendar-mcp",
            template: MCPServerConfig(
                name: "Google Calendar",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@cocal/google-calendar-mcp"],
                    env: ["GOOGLE_OAUTH_CREDENTIALS": FileManager.default.homeDirectoryForCurrentUser.path + "/gcp-oauth.keys.json"]
                ),
                enabled: true
            ),
            setupHint: "Needs a Google Cloud OAuth client (Desktop type) with the Calendar API enabled — point GOOGLE_OAUTH_CREDENTIALS at the downloaded JSON. A browser opens for consent on first use."
        ),
        MCPCatalogEntry(
            id: "gdrive",
            name: "Google Drive",
            description: "Search and read files stored in your Google Drive.",
            iconSystemName: "externaldrive.fill",
            category: .files,
            officialURL: "https://github.com/modelcontextprotocol/servers-archived/tree/main/src/gdrive",
            template: MCPServerConfig(
                name: "Google Drive",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@modelcontextprotocol/server-gdrive"],
                    env: ["GDRIVE_CREDENTIALS_PATH": FileManager.default.homeDirectoryForCurrentUser.path + "/.gdrive-server-credentials.json"]
                ),
                enabled: true
            ),
            setupHint: "Reference server (archived upstream, still functional). Needs Google Cloud OAuth credentials and a one-time auth run — see the linked README."
        ),
        MCPCatalogEntry(
            id: "google-maps",
            name: "Google Maps",
            description: "Directions, travel times, and place details.",
            iconSystemName: "map.fill",
            category: .web,
            officialURL: "https://github.com/modelcontextprotocol/servers-archived/tree/main/src/google-maps",
            template: MCPServerConfig(
                name: "Google Maps",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@modelcontextprotocol/server-google-maps"],
                    env: ["GOOGLE_MAPS_API_KEY": ""]
                ),
                enabled: true
            ),
            setupHint: "Requires a Google Maps API key — fill GOOGLE_MAPS_API_KEY after install."
        ),

        // MARK: Apple apps

        MCPCatalogEntry(
            id: "apple-suite",
            name: "Apple Suite",
            description: "Mail, Messages, Calendar, Reminders, Contacts, and Maps — the whole Apple stack in one server.",
            iconSystemName: "apple.logo",
            category: .appleApps,
            officialURL: "https://github.com/Dhravya/apple-mcp",
            template: MCPServerConfig(
                name: "Apple Suite",
                transport: .stdio(
                    command: "bunx",
                    args: ["--no-cache", "apple-mcp@latest"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Requires bun (brew install oven-sh/bun/bun). macOS will ask for Automation permission per app on first use. Keep per-call approval ON — it can send messages and email."
        ),
        MCPCatalogEntry(
            id: "apple-reminders",
            name: "Apple Reminders",
            description: "Read, create, and complete reminders in the Reminders app.",
            iconSystemName: "checklist",
            category: .appleApps,
            officialURL: "https://github.com/FradSer/mcp-server-apple-reminders",
            template: MCPServerConfig(
                name: "Apple Reminders",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "mcp-server-apple-reminders"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "macOS asks for Reminders permission on first use."
        ),
        MCPCatalogEntry(
            id: "apple-shortcuts",
            name: "Apple Shortcuts",
            description: "List and run your Shortcuts — anything you've automated becomes a tool.",
            iconSystemName: "square.2.layers.3d",
            category: .appleApps,
            officialURL: "https://github.com/recursechat/mcp-server-apple-shortcuts",
            template: MCPServerConfig(
                name: "Apple Shortcuts",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "mcp-server-apple-shortcuts"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Runs your existing Shortcuts. Keep per-call approval ON if any shortcut has side effects."
        ),

        // MARK: Productivity & communication

        MCPCatalogEntry(
            id: "notion",
            name: "Notion",
            description: "Search, read, and update pages and databases in your Notion workspace.",
            iconSystemName: "doc.richtext",
            category: .productivity,
            officialURL: "https://github.com/makenotion/notion-mcp-server",
            template: MCPServerConfig(
                name: "Notion",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@notionhq/notion-mcp-server"],
                    env: ["NOTION_TOKEN": ""]
                ),
                enabled: true
            ),
            setupHint: "Notion's official server. Create an internal integration at notion.so/profile/integrations, share your pages with it, and fill NOTION_TOKEN."
        ),
        MCPCatalogEntry(
            id: "slack",
            name: "Slack",
            description: "Read channels and post messages in your Slack workspace.",
            iconSystemName: "bubble.left.and.bubble.right.fill",
            category: .communication,
            officialURL: "https://github.com/modelcontextprotocol/servers-archived/tree/main/src/slack",
            template: MCPServerConfig(
                name: "Slack",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@modelcontextprotocol/server-slack"],
                    env: ["SLACK_BOT_TOKEN": "", "SLACK_TEAM_ID": ""]
                ),
                enabled: true
            ),
            setupHint: "Reference server (archived upstream, still functional). Needs a Slack bot token (xoxb-…) and your team ID."
        ),
        MCPCatalogEntry(
            id: "todoist",
            name: "Todoist",
            description: "Manage your Todoist tasks — add, complete, search, and plan.",
            iconSystemName: "checkmark.circle.fill",
            category: .productivity,
            officialURL: "https://github.com/abhiz123/todoist-mcp-server",
            template: MCPServerConfig(
                name: "Todoist",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "@abhiz123/todoist-mcp-server"],
                    env: ["TODOIST_API_TOKEN": ""]
                ),
                enabled: true
            ),
            setupHint: "Fill TODOIST_API_TOKEN from Todoist Settings → Integrations → Developer."
        ),
        MCPCatalogEntry(
            id: "kubernetes",
            name: "Kubernetes",
            description: "Inspect pods, deployments, and logs in your clusters via kubectl.",
            iconSystemName: "shippingbox.fill",
            category: .dev,
            officialURL: "https://github.com/Flux159/mcp-server-kubernetes",
            template: MCPServerConfig(
                name: "Kubernetes",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "mcp-server-kubernetes"],
                    env: nil
                ),
                enabled: true
            ),
            setupHint: "Uses your current kubectl context (~/.kube/config). Keep per-call approval ON for anything beyond read-only."
        )
    ]

    static func entries(in category: MCPCatalogEntry.Category) -> [MCPCatalogEntry] {
        all.filter { $0.category == category }
    }
}
