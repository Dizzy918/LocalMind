# Launch checklist

The steps that need a human (you) — roughly in order. Everything code-side is already in the repo.

## Before launch (blockers)

- [ ] **Apple Developer account** ($99/yr) → set the six signing secrets from [DISTRIBUTION.md](DISTRIBUTION.md) so releases are signed & notarized. Do not launch with unsigned builds.
- [ ] **Sparkle keys**: run `./bin/generate_keys` from a [Sparkle release](https://github.com/sparkle-project/Sparkle/releases) once; put the public key in `Config/Info.plist` (`SUPublicEDKey`) and add the private key as the `SPARKLE_ED_PRIVATE_KEY` repo secret. Details in [DISTRIBUTION.md](DISTRIBUTION.md).
- [ ] **Screenshots**: capture 4-5 (chat with citations, agent team, automations, voice mode, dark mode hero) into `docs/images/`, link them from the README and landing page.
- [ ] **Demo video** (~60s): the killer flow — drag a folder of PDFs in → ask a question → cited answer, offline. Screen Studio or QuickTime is fine. Embed on the landing page; upload to YouTube for embedding elsewhere.
- [ ] **Enable GitHub Pages**: repo Settings → Pages → Source: "GitHub Actions". The site workflow deploys `site/` automatically after that.
- [ ] **Enable GitHub Discussions** (repo Settings → General → Features) as the community home.
- [ ] **App icon**: commission or design a proper icon (the SF Symbol placeholder won't survive a Product Hunt thumbnail).
- [ ] Tag `v1.0.0` and verify the release DMG installs cleanly on a fresh Mac (or a new macOS user account).

## Launch week

- [ ] **Show HN** post — title like "Show HN: LocalMind – a native macOS AI assistant that never phones home (MIT)". Be present in comments all day.
- [ ] **r/LocalLLaMA** post — lead with the demo video and the agents/RAG/automations angle; that crowd already has Ollama running.
- [ ] **r/macapps** — native-app angle.
- [ ] **Product Hunt** — schedule for a Tuesday–Thursday; you need the icon, 4-5 gallery images, and the video.
- [ ] Pin a "Start here" issue/discussion for newcomers arriving from the launch.

## Monetization (when ready)

- [ ] Pick Paddle or Lemon Squeezy (both handle EU VAT as merchant of record).
- [ ] Decide the free/Pro split (suggested: free = chat + one backend + basic KB; Pro = agents, pipelines, automations, memory, voice mode).
- [ ] One-time price with launch discount (suggested: $39, launch $29) — this audience hates subscriptions.
- [ ] Offline license validation only — no phone-home DRM; say so on the pricing page.

## Ongoing

- [ ] Update the Homebrew tap after each release (version + sha256 in the cask).
- [ ] Keep `CHANGELOG.md` honest with every release; releases with human-written notes convert lurkers.
- [ ] Merge/curate community pack PRs.
