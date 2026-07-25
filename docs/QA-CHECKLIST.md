# Manual QA Checklist

The unit suite covers logic; this covers the things it structurally cannot —
anything that needs a live model, a real MCP server, the system's Shortcuts
database, or a human looking at the screen. Run it before tagging a release.

Times are rough. The whole pass is about 30–40 minutes.

**How to use this:** work top to bottom. Anything that fails is a release
blocker unless noted otherwise. Record failures as issues rather than fixing
them mid-pass, so the pass finishes and you learn everything that's broken
rather than the first thing.

---

## 0. Setup (5 min)

- [ ] Ollama running (`ollama serve`) with at least one chat model pulled
- [ ] A second backend available if you can — LM Studio, or Apple Intelligence
      on a supported Mac
- [ ] The filesystem MCP server installed from the in-app catalog
- [ ] A folder with a few PDFs or text files, for the knowledge base

---

## 1. Tool calling — the highest-risk path (10 min)

Tools were, for a long time, requested but never fed back to the model. The
whole loop only exists as of recent work, so it gets checked first and hardest.

- [ ] **Chat.** Ask something that requires the tool: *"what files are in my
      Downloads folder?"* Expect: approval prompt → tool runs → the model
      **answers using the result**, not just a dump of raw output.
- [ ] The answer carries a tool chip underneath. Expand it: arguments and
      result are both shown, with a duration.
- [ ] **Restart the app.** Reopen that conversation — the tool chip and its
      contents are still there. (Tool runs used to vanish with the session.)
- [ ] **Deny** a tool call when prompted. The model should say it couldn't
      run the tool, not hang or produce a fake answer.
- [ ] **Quick panel** (menu bar / global hotkey). Ask the same question.
      Tools should work here too.
- [ ] **Pipeline.** Build a two-step pipeline where step one uses an agent with
      tools enabled. Run it. Step one should actually call the tool, and the
      step should show what it ran.
- [ ] **Apple Intelligence**, if available: switch to it in Providers and repeat
      the chat test. The framework runs its own tool loop here, so this is a
      genuinely different code path.

## 2. Shortcuts / App Intents (5 min)

- [ ] Open **Shortcuts.app** → search "LocalMind". Three actions appear: Ask
      LocalMind, Search LocalMind Documents, New LocalMind Chat.
- [ ] Run **Ask LocalMind** with a prompt. It returns text you can pipe into
      another action — not just opening the app.
- [ ] Set **Save to History** off, run it again: no new conversation appears in
      the sidebar.
- [ ] Run **Ask LocalMind** with an agent name that exists. The answer should
      carry that agent's persona.
- [ ] Stop Ollama and run it again: you get a readable error, not a hang and
      not `⚠️ …` returned as if it were the answer.
- [ ] **Spotlight**: type "Ask LocalMind" — the action is offered.

## 3. Knowledge base (5 min)

- [ ] Import a folder. Documents appear with chunk counts.
- [ ] Ask a question whose answer is in one document. The answer cites it.
- [ ] Ask about an **exact string** — an error code, a filename, an unusual
      proper noun. This is what the keyword half of hybrid search is for; pure
      embeddings tend to miss it.
- [ ] **Rebuild index.** It reports how many documents were rebuilt. Search
      still works afterwards.
- [ ] **Switch embedding model** (Apple ↔ Ollama, needs `nomic-embed-text`
      pulled) and rebuild. Your documents survive the switch — this used to
      require deleting them all.

## 4. Conversations & data (5 min)

- [ ] Send a message in a new chat; it gets a title and emoji shortly after.
- [ ] Search the sidebar. Results appear as you type, with no lag.
- [ ] Edit an old message and regenerate. The variant navigator (‹ 1/2 › ) works.
- [ ] Add a **tag** via right-click → Tags → New Tag. The filter bar appears;
      clicking the tag filters the list; clicking again clears it.
- [ ] Tag survives a restart.
- [ ] Right-click a tag in the filter bar → delete it everywhere.
- [ ] **Archive**, **pin**, and **merge** each behave.
- [ ] Delete a conversation. It disappears and doesn't come back on relaunch.

## 5. Usage insights (2 min)

- [ ] Settings → Usage. Numbers are populated and plausible.
- [ ] With Ollama, the token count says it was counted by the model server.
      With a backend that doesn't report usage, the tooltip admits the figure
      is estimated.

## 6. Multi-backend behaviour (5 min)

- [ ] Stop Ollama mid-conversation. The app notices and says so; it doesn't
      spin forever.
- [ ] Restart it. The app reconnects on its own within a few seconds.
- [ ] Pin an agent to a backend that isn't the active one and ask it something.
      It should answer via that backend.

## 7. Windows, menu bar, restore (3 min)

- [ ] Close the last window, then **File → New Window**. A window comes back.
      (Without this the menu-bar app can end up running with no way in.)
- [ ] Quit and relaunch with the tabbed layout on: tabs restore.
- [ ] Switch profiles: the sidebar and tab strip show only that profile's chats.

## 8. Updates (2 min)

- [ ] **LocalMind → Check for Updates…** completes without error.
- [ ] `SUPublicEDKey` is set in `Config/Info.plist`. **If it is not, updates are
      only protected by the Developer ID signature and this is a release
      blocker** — generate the key with Sparkle's `generate_keys` and add it.

---

## Remote MCP servers (only when you have one)

Untested against a live authorization server — treat the first real sign-in as
a trial rather than a regression check.

- [ ] Add an HTTP MCP server that requires OAuth. Menu → **Sign In…** opens the
      browser; approving returns to the app and the server connects.
- [ ] Its tools appear and can be called.
- [ ] Quit and relaunch: still signed in (the token is in the Keychain).
- [ ] **Sign Out** and confirm the server stops authenticating.

---

## Recording results

Note the build (`git rev-parse --short HEAD`), the macOS version, and which
backends you exercised. A pass on Ollama says nothing about the Apple
Intelligence path — they share almost no code below the service protocol.
