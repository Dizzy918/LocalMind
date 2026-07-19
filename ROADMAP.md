# Roadmap

What's planned for LocalMind, roughly in order. This is a living document — items move as reality intervenes. Have an opinion? Open an issue.

## Near term

- **Signed & notarized releases** — official builds that open without Gatekeeper warnings
- **Auto-updates** — in-app updates via Sparkle, so a DMG is downloaded once, ever
- **First-run onboarding** — from empty Mac to first answer in under two minutes
- **Community agent & pipeline gallery** — curated, importable packs in `community/`

## Next

- **Conversation tags** — organize loose chats without forcing them into projects
- **Usage insights** — local-only stats: tokens/sec by model, most-used agents, generation time
- **Knowledge base collection manager** — rename/merge/delete collections in one place
- **Pipeline step transcripts** — inspect each intermediate step of a pipeline run
- **Shortcuts app intents** — first-class Shortcuts actions beyond the URL scheme
- **Drag & drop conversations** into projects in the sidebar

## Later

- **Split DataStore internals** — faster cold launch with very large histories
- **Localization** — starting with the languages contributors bring
- **Model recommendation refinements** — smarter suggestions by chip generation, not just RAM
- **Local network sync** — move your data between your own Macs without any cloud (research stage)

## Explicit non-goals

- **No cloud backend, ever.** A hosted LocalMind defeats the point.
- **No telemetry**, including "anonymous usage statistics."
- **No cross-platform port** while it would dilute the native macOS experience.
