# LocalMind Tests

Unit tests for LocalMind's core logic, using Apple's [XCTest framework](https://developer.apple.com/documentation/xctest).

## One-time Setup

The test target is not committed to `project.pbxproj` to keep the project file minimal. Add it once in Xcode:

1. Open `LocalMind.xcodeproj`.
2. **File → New → Target…** → macOS → **Unit Testing Bundle** → Next.
3. Product name: `LocalMindTests`. Target to be Tested: `LocalMind`. Finish.
4. Delete the auto-generated `LocalMindTests/LocalMindTests.swift` placeholder.
5. Right-click the `LocalMindTests` group → **Add Files to "LocalMind"…**
6. Select every `.swift` file under `Tests/LocalMindTests/`. In the dialog, untick **LocalMind** and tick **LocalMindTests**. Choose **Create groups** (not folder references). Add.
7. Edit the `LocalMind` scheme → **Test** → **+** → add `LocalMindTests`.
8. Press **⌘U**.

Once added, enable the `test` job in `.github/workflows/build.yml` (set `if: false` → remove the line).

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
