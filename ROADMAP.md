# Roadmap

What's planned for LocalMind, roughly in order. This is a living document — items move as reality intervenes. Have an opinion? Open an issue.

## Near term

- **Sparkle update signing** — generate the EdDSA key and set `SUPublicEDKey`, so updates are signature-verified as well as Developer ID signed
- **Conversation tags** — organize loose chats without forcing them into projects
- **Usage insights** — local-only stats: tokens/sec by model, most-used agents, generation time (now that backends' real token counts are recorded)
- **Pipeline step transcripts** — inspect each intermediate step of a pipeline run

## Next

- **Tool calling for Apple Intelligence** — the on-device backend can't use MCP tools yet, so tools silently do nothing when it's selected
- **Remote MCP servers with OAuth** — HTTP transport exists but only takes static headers; the ecosystem is moving to OAuth
- **Knowledge base collection manager** — rename/merge/delete collections in one place
- **Consolidate the multi-agent surfaces** — agents, teams, debate, auto-routing, and pipelines overlap; it isn't obvious which to reach for
- **Drag & drop conversations** into projects in the sidebar

## Shipped

- **Signed & notarized releases**, **Sparkle auto-updates**, **first-run onboarding**, and the **community agent & pipeline gallery**
- **Shortcuts app intents** — Ask / Search Documents / New Chat, returning results to the shortcut

## Later

- **Split DataStore internals** — faster cold launch with very large histories
- **Localization** — starting with the languages contributors bring
- **Model recommendation refinements** — smarter suggestions by chip generation, not just RAM
- **Local network sync** — move your data between your own Macs without any cloud (research stage)

## Explicit non-goals

- **No cloud backend, ever.** A hosted LocalMind defeats the point.
- **No telemetry**, including "anonymous usage statistics."
- **No cross-platform port** while it would dilute the native macOS experience.
