# Proposal: consolidate the multi-agent surfaces

**Status:** proposal, nothing implemented. This is a recommendation to accept,
reject, or amend — these are features you built deliberately, and cutting them
isn't a call to make unilaterally.

## The problem

There are five ways to get more than one perspective on a question, and no
obvious rule for picking between them:

| Surface | Where | What it does |
|---|---|---|
| **Agents** | Sidebar / per-conversation | One persona answers |
| **Auto-routing** | Per-conversation toggle | A model picks the agent per message |
| **Agent teams** | Sheet from chat | N agents answer the same question in parallel |
| **Debate mode** | Inside the team sheet | A moderator declares a winner |
| **Pipelines** | Sheet from chat | N agents in sequence, each transforming the last output |

A new user cannot tell from the names which one they want, and three of them
(teams, debate, pipelines) live behind sheets that most people will never open.
The overlap also has a real maintenance cost: this session found tools silently
disabled in pipelines precisely because the code path was separate and
under-exercised.

The distinction that actually matters is **parallel vs. sequential** — teams
fan out, pipelines chain. Everything else is a variation on those two.

## What I'd propose

**Keep, unchanged:**

- **Agents.** The core concept everything else composes. Not in question.
- **Pipelines.** Sequential chaining is genuinely distinct, and the step
  transcripts now make it inspectable. This is the strongest of the multi-agent
  features.

**Merge:**

- **Debate mode into Agent teams.** Debate isn't a separate mode — it's a team
  run plus a moderator pass. It already lives inside the team sheet. Present it
  as what it is: a "Compare / Synthesize / Pick a winner" control on the team
  result, not a mode you enter.

**Demote:**

- **Auto-routing.** It's a per-conversation toggle that spends an extra model
  round-trip to guess which persona should answer, and when it guesses wrong the
  user gets a confidently mis-specialised answer with no obvious cause. It's a
  neat trick that's hard to trust. I'd move it out of the per-conversation UI
  into a global setting, default off, described honestly as experimental.

**Rename:**

- **"Agent teams" → "Compare answers"** (or similar). The current name describes
  the mechanism; the proposed one describes the outcome. Nobody wakes up wanting
  a team — they want to see whether two models disagree.

## What this buys

- Five entry points become three: *one agent*, *compare several*, *chain
  several*.
- The two sequential/parallel paths stay, so no capability is actually lost —
  debate and auto-routing remain reachable, just not as top-level concepts.
- Fewer separate code paths that can drift, which is what caused the pipeline
  tool bug.

## What it costs

- UI churn for existing users who know where things are.
- Auto-routing becoming a setting means people who like it have to go find it.
- Renaming means the docs, landing page, and community pack descriptions need
  updating.

## What I'd want to know first

This is the honest caveat: **I'm proposing this from code structure, not from
evidence about use.** Your no-telemetry stance is right and it also means
neither of us knows whether anyone uses debate mode.

Before acting on this, I'd want one qualitative signal — a GitHub Discussion
asking which of these people actually use, or even a handful of replies to a
release note. If it turns out debate mode is someone's favourite feature, this
proposal is wrong and should be dropped.

**Suggested sequence:** ship 1.0 with all five as they are, ask the question in
the release notes, and revisit this after there are answers. Nothing here is
urgent enough to gate a release.
