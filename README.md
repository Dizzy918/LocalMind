# LocalMind

A private, local-first AI assistant for macOS. All conversations stay on your device — no cloud, no telemetry, no subscriptions.

LocalMind connects to local AI backends running on your machine and provides a clean, modern chat interface inspired by Claude, ChatGPT, and Gemini.

![macOS](https://img.shields.io/badge/macOS-26.0%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)
![License](https://img.shields.io/badge/License-MIT-blue)

## Features

- **Multiple AI Backends** — Apple Intelligence, Ollama, LM Studio, and any OpenAI-compatible server
- **Auto-detection** — automatically discovers running AI servers and connects
- **Modern Chat UI** — centered content column, suggestion chips, hover actions, markdown rendering
- **Voice Input** — speech-to-text with live waveform visualization and auto-punctuation
- **Text-to-Speech** — read AI responses aloud
- **Vision** — drag & drop or paste images for analysis (requires a vision model like LLaVA)
- **File Attachments** — drop PDFs and text files directly into the chat
- **Full-Text Search** — search across all conversation content, not just titles
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

- **macOS 26.0** (Tahoe) or later
- **Xcode 26** or later
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

### 2. Open in Xcode

```bash
open LocalMind.xcodeproj
```

No external dependencies — the project uses only Apple frameworks.

### 3. Build and Run

Select the **LocalMind** scheme, choose **My Mac** as the destination, and hit `Cmd + R`.

### 4. Set up an AI backend

The app will auto-detect any running local AI server. The easiest way to get started:

**Option A: Ollama (recommended)**
```bash
# Install Ollama
brew install ollama

# Start the server
ollama serve

# Pull a model (in another terminal)
ollama pull qwen3:8b
```

**Option B: LM Studio**

Download from [lmstudio.ai](https://lmstudio.ai), load a model, and start the local server.

**Option C: Apple Intelligence**

On supported Apple Silicon Macs running macOS 26+, Apple Intelligence is available as a built-in backend with no setup required.

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
│   ├── CustomTool.swift        # User-defined AI tools
│   ├── FocusSession.swift      # Focus timer sessions
│   └── TaskItem.swift          # Task definitions
├── Services/
│   ├── AIServiceProtocol.swift # Backend protocol + AIServiceError
│   ├── AIServiceManager.swift  # Auto-detection, polling, model switching
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
- **System Prompt** — customize the default AI personality
- **Temperature / Top-P** — tune generation parameters
- **Context Limit** — control how many messages are sent as context
- **Auto-Read Responses** — toggle automatic text-to-speech

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
