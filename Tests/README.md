# LocalMind Tests

Unit tests for LocalMind's core logic.

## Running the Tests

The tests live in `Tests/LocalMindTests/` and use Apple's [XCTest framework](https://developer.apple.com/documentation/xctest).

### One-time Setup (30 seconds)

LocalMind ships without a test target in the Xcode project to keep the project file small.
To run the tests, add a test target once:

1. Open `LocalMind.xcodeproj` in Xcode
2. **File → New → Target...**
3. Choose **Unit Testing Bundle** (under macOS → Test)
4. Name it `LocalMindTests`, set the **Target to be Tested** to `LocalMind`, click Finish
5. In the new `LocalMindTests` group, **right-click → Add Files to "LocalMindTests"...**
6. Navigate to `Tests/LocalMindTests/` and select all `.swift` files. Make sure **"Add to target: LocalMindTests"** is checked
7. Delete the auto-generated `LocalMindTests.swift` placeholder file
8. Press **⌘ + U** to run all tests

### Running from Command Line

After setup, you can also run tests from the terminal:

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
| `ChatMessage` tests | Message encoding/decoding with images and attachments |
| `DataStoreTests.swift` | Save, retrieve, delete, search across titles and message content, multi-word search, sorting |
| `AIServiceErrorTests.swift` | All error cases have user-facing descriptions and actionable recovery suggestions |

## Adding New Tests

1. Add a new `.swift` file under `Tests/LocalMindTests/`
2. Make sure to add it to the `LocalMindTests` target in Xcode (right-click → Add Files)
3. Import `XCTest` and use `@testable import LocalMind`
4. Follow the existing naming pattern: `[Subject]Tests.swift`

## What's NOT Tested

These require integration with running services and are not covered by unit tests:

- Live AI streaming responses (mocked at the protocol level)
- File system migrations between LocalAIHelper → LocalMind
- Voice recognition / speech synthesis (requires hardware)
- macOS-specific UI behavior (sidebar, window state, hotkeys)

For these, manual testing is recommended.
