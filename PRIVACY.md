# Privacy

LocalMind's core promise: **your conversations, documents, and memory never leave your Mac.** This page lists every network connection the app can make, so you can verify the claim instead of taking our word for it.

## What stays on your Mac (everything)

| Data | Where it lives |
|------|----------------|
| Conversations | `~/Library/Application Support/LocalMind/conversations/` |
| Knowledge base documents & embeddings | `~/Library/Application Support/LocalMind/knowledge.json` |
| Cross-chat memory index | `~/Library/Application Support/LocalMind/` |
| Agents, projects, pipelines, snippets, automations | `~/Library/Application Support/LocalMind/` |
| Settings | `~/Library/Preferences` (UserDefaults) |

All of it is plain JSON on your disk. You can read it, back it up, or delete it at any time. There is no account, no sign-up, and no server-side anything.

## Every network connection, listed

LocalMind itself makes **no connections to the internet**. Here is the complete list of what it does connect to:

1. **`localhost` AI backends.** Ollama (`127.0.0.1:11434`), LM Studio (`127.0.0.1:1234`), or any OpenAI-compatible server URL you configure. Your prompts go to that process on your machine and nowhere else. If you point the OpenAI-compatible backend at a *remote* URL, your prompts go to that server — that's your choice and under your control.

2. **Model downloads.** When you pull a model from the in-app Model Manager, LocalMind asks your local Ollama daemon to download it; Ollama then fetches it from `ollama.com`. LocalMind never talks to the registry itself.

3. **MCP servers you install.** MCP tools run as local processes you configure (typically via `npx`, which downloads the server package from the npm registry on first run). A tool like "Web Search" will, obviously, search the web when an agent calls it. MCP tools are off by default, opt-in per agent, and every configured server is visible in Settings → MCP Servers.

4. **Software updates.** Update checks fetch a static file from this repository's GitHub releases to compare version numbers. No identifier, no telemetry — a plain HTTPS GET that can be disabled in Settings.

That's the whole list.

## What LocalMind does not do

- **No telemetry, no analytics, no crash reporting.** There is no tracking SDK in the binary. Nothing is phoned home, ever.
- **No accounts.** Profiles in LocalMind are local display names, not cloud identities.
- **No silent cloud fallback.** If no local backend is available, the app says so — it never quietly routes your prompt to a hosted API.

## Verify it yourself

Don't trust — check:

- Run [Little Snitch](https://www.obdev.at/products/littlesnitch/) or `nettop -p LocalMind` and watch the connections: you'll see localhost traffic and nothing else during normal use.
- The entire source is public in this repository. Search it: `grep -ri "api.openai.com\|anthropic\|telemetry\|analytics" LocalMind/` returns nothing.
- Build it yourself from source and compare behavior.

## Microphone & speech

Voice input and voice mode use Apple's on-device speech recognition (`SFSpeechRecognizer` with on-device recognition where supported). Audio is processed locally; the app asks for microphone and speech permissions the first time you use a voice feature, and never records in the background.

## Questions

Open an issue — privacy questions get answered in public so everyone benefits from the answer.
