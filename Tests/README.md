# LocalMind Tests

Unit tests for LocalMind's core logic, using Apple's [XCTest framework](https://developer.apple.com/documentation/xctest).

## Setup

The `LocalMindTests` target is already committed to `project.pbxproj` and wired into the `LocalMind` scheme — no manual setup needed. Open the project and press **⌘U**, or use the command line below. CI runs the suite on every push via the `test` job in `.github/workflows/build.yml`.

## Running

```bash
xcodebuild test \
  -project LocalMind.xcodeproj \
  -scheme LocalMind \
  -destination 'platform=macOS'
```

## Test Files

| File | Coverage |
|------|----------|
| `ConversationTests.swift` | Conversation model, title generation, codable round-trips, graceful fallback for unknown tool types |
| `DataStoreTests.swift` | Save, retrieve, delete, search across titles and message content, multi-word search, sorting |
| `AIServiceErrorTests.swift` | All error cases have user-facing descriptions and actionable recovery suggestions |
| `NewConversationSendTests.swift` | Regression guard for the new-conversation send race — every binding mutation in `sendMessage()` is observable on the next read |
| `ImportedMemoryTests.swift` | Cross-AI memory import parser tolerates markdown fences, leading prose, and other messy shapes |
| `MCPHelpersTests.swift` | Pure-function MCP plumbing — slug formatter, saved-config migrator, executable resolver, SSE event splitter |
| `EmbeddingTests.swift` | Retrieval math — cosine similarity edge cases and the document chunker (paragraph packing, hard-splitting) |

## Adding New Tests

1. Add a new `.swift` file under `Tests/LocalMindTests/`.
2. Add it to the `LocalMindTests` target in Xcode (right-click → Add Files).
3. `import XCTest` and `@testable import LocalMind`.
4. Naming: `[Subject]Tests.swift`.

## What's NOT Tested

Manual testing required for:

- Live AI streaming responses
- File system migrations between LocalAIHelper → LocalMind
- Voice recognition / speech synthesis
- macOS UI behavior (sidebar, window state, hotkeys)
