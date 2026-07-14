# LocalMind

A private, local-first AI assistant for macOS. All conversations stay on your device — no cloud, no telemetry, no subscriptions.

LocalMind connects to local AI backends running on your machine and provides a clean, modern chat interface inspired by Claude, ChatGPT, and Gemini.

![macOS](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)
![License](https://img.shields.io/badge/License-MIT-blue)

## Features

- **Multiple AI Backends** — Apple Intelligence, Ollama, LM Studio, and any OpenAI-compatible server
- **Auto-detection** — automatically discovers running AI servers and connects
- **Modern Chat UI** — centered content column, suggestion chips, hover actions, markdown rendering
- **Message Editing** — edit past user messages to fork the conversation from that point
- **Regenerate Responses** — get a different answer with one click
- **Pin & Archive** — pin important conversations to the top, archive old ones
- **Multi-format Export** — Markdown, JSON, HTML, or plain text
- **Token Counter** — approximate token count shown per conversation
- **Voice Input** — speech-to-text with live waveform visualization and auto-punctuation
- **Text-to-Speech** — read AI responses aloud
- **Vision** — drag & drop or paste images for analysis (requires a vision model like LLaVA)
- **File Attachments** — drop PDFs and text files directly into the chat
- **Chat with Your Documents** — add PDFs/text files (or whole folders, via picker or drag-and-drop) to a local knowledge base; relevant passages are retrieved, **cited**, and grounded into answers. Embeds on-device via Apple's NaturalLanguage by default, or via Ollama's `nomic-embed-text` for higher-quality retrieval — nothing is uploaded
- **Agents** — create reusable AI personas, each with its own instructions, pinned backend & model, creativity level, and tool/knowledge-base access; assign one per conversation. Ships with starter agents (Researcher, Coder, Writer, Critic)
- **Agent Team** — send one prompt to up to 4 agents at once and watch them answer in parallel, side by side — even across different backends (Ollama next to Apple Intelligence); then synthesize their answers into one, or continue any answer as a normal chat
- **Auto-Routing** — flip a conversation to "Auto" and each message is classified and routed to the best-fitting agent; every answer is labeled with the agent and model that produced it
- **Debate Mode** — after a team run, agents read each other's answers, critique them, and revise over multiple rounds; an impartial moderator can declare a winner
- **Background Generation** — switching conversations no longer cancels an answer; chats generate in parallel, with a spinner in the sidebar while streaming and an unread dot when a reply finished elsewhere
- **Visible Reasoning** — thinking models' chain-of-thought streams into a collapsed 💭 disclosure instead of being discarded, with a live "Thinking…" state
- **Smart Context** — messages are selected by token budget (not just count), and a rolling summary keeps the gist of older messages in context on long conversations
- **Cross-Chat Memory** — opt-in recall of relevant exchanges from your other conversations, embedded and searched entirely on-device
- **In-App Model Manager** — pull Ollama models with a progress bar, delete them, and browse any backend's catalogue without touching a terminal (Settings → Providers)
- **Automation** — `localmind://ask?prompt=…&agent=Coder` starts an (agent-routed) chat from Shortcuts, scripts, or other apps
- **Knowledge Collections** — group documents into named sets and point each agent at just the collections it needs
- **Watched Folders** — point the knowledge base at a folder and its files are indexed and kept in sync automatically as they change on disk
- **Per-Message Stats** — every answer shows the model, tokens/sec, and generation time
- **Agent Import/Export** — share agent packs as JSON files (Settings → Agents)
- **Per-Agent Tool Allowlists** — limit an agent to specific MCP tools, or disable tools for it entirely; pre-approved tools also work in team runs
- **Per-Conversation Model & Temperature** — pin a specific model or creativity level for one chat without changing your global default
- **Compare Models Side-by-Side** — regenerate any answer with another model and keep the one you prefer
- **Conversation Branches** — editing or regenerating saves the previous version so you can restore it
- **Tool-Call Approval & Audit** — approve each MCP tool call before it runs and review a log of what the AI did
- **Full-Text Search** — multi-word search across all conversation content, not just titles
- **Custom Tools** — create reusable AI tools with custom system prompts
- **Menu Bar App** — quick access from the menu bar without switching windows
- **Global Hotkey** — summon a floating bubble window from anywhere
- **Focus Timer** — built-in Pomodoro-style focus sessions
- **Draft Recovery** — unsent messages are auto-saved and restored
- **Conversation Compression** — large conversations are automatically gzip-compressed on disk
- **Memory Pressure Monitoring** — pauses background polling and notifies you when system memory is low
- **Dark & Light Mode** — full theme support with one-click toggle
- **Fully Private** — everything runs locally, data stored in `~/Library/Application Support/LocalMind/`

## Requirements

- **To run:** macOS 15 (Sequoia) or later. The Apple Intelligence backend additionally requires macOS 26+ on supported hardware; every other backend works on macOS 15+.
- **To build from source:** full **Xcode 26 or later** (download from the App Store). The Apple Intelligence backend builds against the Foundation Models SDK introduced in Xcode 26.
- One of the following AI backends:
  - [Ollama](https://ollama.com) (recommended)
  - [LM Studio](https://lmstudio.ai)
  - Any OpenAI-compatible local server
  - Apple Intelligence (on supported hardware)

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/Dizzy918/LocalMind.git
cd LocalMind
```

### 2. Build and Run

**Option A: Using Xcode (GUI)**

```bash
open LocalMind.xcodeproj
```

Select the **LocalMind** scheme, choose **My Mac** as the destination, and hit `Cmd + R`.

**Option B: Using Command Line**

```bash
# Build the app
xcodebuild -project LocalMind.xcodeproj -scheme LocalMind -configuration Debug -destination 'platform=macOS' build
```

`xcodebuild` builds but doesn't launch the app — open the resulting `LocalMind.app` from `~/Library/Developer/Xcode/DerivedData/`, or just use Option A to build and run from Xcode.

No external dependencies — the project uses only Apple frameworks.

### 3. Set up an AI backend

The app will auto-detect any running local AI server. Pick whichever fits your needs:

#### Option A: Ollama (recommended for most users)

Best for: easy setup, wide model selection, terminal-friendly.

```bash
# Install Ollama
brew install ollama

# Start the server (leave running in a background terminal)
ollama serve

# Pull a model (in another terminal)
ollama pull qwen3:8b
```

**Recommended models by use case:**

| Use case | Model | Size | Notes |
|----------|-------|------|-------|
| General chat (balanced) | `qwen3:8b` | ~5 GB | Default. Fast, smart, great for most tasks |
| Faster, smaller | `llama3.2:3b` | ~2 GB | Quick on lower-end Macs |
| Coding | `qwen2.5-coder:7b` | ~4.5 GB | Specifically tuned for code |
| Strong reasoning | `qwen3:14b` | ~9 GB | Slower but more capable |
| Vision (images) | `llava:7b` | ~4.5 GB | Required for image analysis |
| Highest quality | `qwen3:32b` | ~20 GB | Needs M2 Pro / M3 Pro+ with 32 GB+ RAM |

Hardware guidance:
- **8 GB RAM**: stick to 3B–4B models (`llama3.2:3b`, `phi3:mini`)
- **16 GB RAM**: 7B–8B models work comfortably
- **32 GB RAM**: can run 14B–20B models
- **64 GB+ RAM**: 32B–70B models become viable

#### Option B: LM Studio (GUI alternative)

Best for: model discovery via a UI, easy switching between models.

1. Download from [lmstudio.ai](https://lmstudio.ai)
2. Search and download a model (e.g. `Llama 3.2 8B Instruct`)
3. Go to the **Local Server** tab → load your model → click **Start Server**
4. LocalMind will auto-detect it on `http://localhost:1234`

#### Option C: Apple Intelligence (zero setup)

Best for: Apple Silicon Macs with macOS 26+, when you want something that just works.

- No installation needed — uses the on-device Foundation Models
- Lower quality than 7B+ Ollama models, but instant and battery-friendly
- Requires Apple Intelligence to be enabled in System Settings

#### Option D: Any OpenAI-compatible server

LocalMind speaks the OpenAI API spec, so it works with:
- [Jan](https://jan.ai)
- [Text Generation WebUI](https://github.com/oobabooga/text-generation-webui)
- [llama.cpp server](https://github.com/ggerganov/llama.cpp)
- vLLM, llamafile, koboldcpp, etc.

Point LocalMind at the server's base URL in Settings → AI Backend.

### Vision (Image Analysis) Setup

To analyze images, you need a vision-capable model:

```bash
ollama pull llava:7b
# or for higher quality:
ollama pull llava:13b
```

Then in LocalMind:
1. Click the sidebar model picker, select `llava:7b`
2. Drag an image into the chat (or paste with `Cmd + V`)
3. Ask a question about the image

### Performance Tips

- **First message takes 10-30 seconds** while the model loads into RAM. Subsequent messages are instant.
- LocalMind keeps Ollama models loaded for **1 hour** after the last message to avoid reload latency
- For best speed, close other RAM-heavy apps (Chrome, Docker) before chatting
- M-series Macs are dramatically faster than Intel Macs due to unified memory architecture

Once a backend is running, LocalMind will detect it automatically and show a green status indicator in the sidebar.

## Project Structure

```
LocalMind/
├── LocalMindApp.swift          # App entry point, window setup, menu bar
├── ContentView.swift           # Main layout (sidebar + chat)
├── Models/
│   ├── ChatMessage.swift       # Message model with image/file support
│   ├── Conversation.swift      # Conversation model with emoji/title
│   ├── AIParameters.swift      # Temperature, top-p, context settings
│   ├── Agent.swift             # AI personas (prompt + model + capabilities)
│   ├── CustomTool.swift        # User-defined AI tools
│   ├── FocusSession.swift      # Focus timer sessions
│   └── TaskItem.swift          # Task definitions
├── Services/
│   ├── AIServiceProtocol.swift # Backend protocol + AIServiceError
│   ├── AIServiceManager.swift  # Auto-detection, polling, cross-backend routing
│   ├── ChatGenerationService.swift # Background generation, auto-routing, rolling summary
│   ├── ChatMemoryStore.swift   # On-device cross-conversation memory
│   ├── OllamaService.swift     # Ollama API client
│   ├── OpenAICompatibleService.swift  # OpenAI-compatible API client
│   ├── AppleFoundationModelService.swift  # Apple Intelligence
│   ├── DataStore.swift         # JSON persistence with compression + search
│   ├── VoiceManager.swift      # Speech recognition + TTS
│   ├── HotkeyManager.swift     # Global keyboard shortcut
│   ├── BubbleWindowController.swift  # Floating bubble window
│   └── MemoryPressureMonitor.swift   # System memory monitoring
├── Theme/
│   ├── Theme.swift             # Design system (colors, typography, spacing)
│   └── Components.swift        # Reusable UI components
└── Views/
    ├── ChatView.swift          # Chat interface with streaming
    ├── AgentTeamView.swift     # Run several agents on one prompt in parallel
    ├── AgentSettingsView.swift # Create/edit/manage agents
    ├── SidebarView.swift       # Navigation + conversation history
    ├── SettingsView.swift      # Preferences panel
    ├── FocusTimerView.swift    # Pomodoro timer
    ├── QuickActionPanel.swift  # Menu bar panel
    ├── BubbleView.swift        # Floating window view
    ├── MessageMarkdownView.swift  # Markdown message renderer
    └── CustomToolSettingsView.swift  # Custom tool editor
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd + Return` | Send message |
| `Cmd + V` | Paste image from clipboard |
| `Up / Down` | Navigate prompt history |
| `Ctrl + Space` | Toggle floating bubble (global) |

## Configuration

All settings are available in the app's Settings panel (`Cmd + ,`):

- **AI Backend** — choose preferred backend or let auto-detect decide
- **Model Selection** — pick from available models on your server
- **Agents** — create and manage AI personas; assign one from the chat header, or run several at once via "Ask multiple agents"
- **System Prompt** — customize the default AI personality
- **Temperature / Top-P** — tune generation parameters
- **Context Limit** — control how many messages are sent as context
- **Auto-Read Responses** — toggle automatic text-to-speech

## Running Tests

Unit tests live in `Tests/LocalMindTests/` and UI smoke tests in `Tests/LocalMindUITests/` — both wired into the `LocalMind` scheme, no setup needed. See [Tests/README.md](Tests/README.md) for the file-by-file breakdown.

```bash
xcodebuild test \
  -project LocalMind.xcodeproj \
  -scheme LocalMind \
  -destination 'platform=macOS'
```

Tests cover the core models, DataStore (save / load / search / compression), and AIServiceError descriptions.

## Data Storage

All data is stored locally at:
```
~/Library/Application Support/LocalMind/
├── conversations/    # Chat history (JSON, gzip-compressed if >50KB)
├── focus_sessions/   # Focus timer records
└── custom_tools/     # User-defined tools
```

No data ever leaves your machine.

## License

MIT License. See [LICENSE](LICENSE) for details.
