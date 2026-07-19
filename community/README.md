# Community agents & pipelines

Curated, ready-to-import packs for LocalMind. Each file is a standard LocalMind JSON export — import it from **Settings → Agents → share menu → Import**.

## Agent packs

| Pack | Agents |
|------|--------|
| [`agents/developer-pack.json`](agents/developer-pack.json) | Code Reviewer · Debugger · Commit Writer · SQL Helper |
| [`agents/productivity-pack.json`](agents/productivity-pack.json) | Email Polisher · Meeting Summarizer · Decision Helper |
| [`agents/writing-pack.json`](agents/writing-pack.json) | Copy Editor · Outliner · Tone Shifter |
| [`agents/learning-pack.json`](agents/learning-pack.json) | Socratic Tutor · ELI5 Explainer · Flashcard Maker |

## Pipelines

| Pipeline | Flow |
|----------|------|
| [`pipelines/draft-review-revise.json`](pipelines/draft-review-revise.json) | Draft → find weaknesses → revise |
| [`pipelines/research-brief.json`](pipelines/research-brief.json) | Gather facts → verify claims → one-page brief |
| [`pipelines/blog-post.json`](pipelines/blog-post.json) | Outline → full draft → tighten & polish |

Pipelines ship with each step running on the default assistant, carrying its instructions in the step itself — so they work before you've imported any agents. After importing an agent pack, edit a pipeline and assign specific agents to steps for even better results.

## Contributing

Made an agent or pipeline worth sharing? Export it from the app (Settings → Agents → share menu) and open a PR adding the file plus a row in the table above. Guidelines:

- One pack = one theme, 2–4 agents.
- System prompts should be self-contained — no references to documents or tools the user may not have.
- Set `useKnowledgeBase` to `false` and leave `backend`/`modelID` unset unless the agent genuinely requires them, so packs work on every setup.
