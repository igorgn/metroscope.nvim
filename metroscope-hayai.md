# Metroscope + Hayai

> Understand your codebase. Plan what to build. Execute with AI. Level up.

---

## The Vision

Most AI coding tools answer one question: *write this code for me.*

This answers a different set of questions:
- *What does this codebase do?*
- *What should I build next?*
- *How should I build it?*
- *What does this decision unlock?*

It's a platform in three acts: **understand**, **plan**, **build**.

---

## The Loop

```
Talk → Plan → Quest → Build
```

### Talk
Freeform conversation with the AI. "I want to add offline sync." The AI asks clarifying questions, pushes back, explores tradeoffs. You figure out what you actually want — and why.

### Plan
The conversation crystallizes into a spec. The AI structures what was agreed: scope, constraints, approach. You review and adjust. The plan is not a document — it becomes a quest.

### Quest
The plan enters the skill tree as a quest. Acts are generated. Forks appear where real decisions need to be made. The quest slots into the tree alongside quests generated from codebase analysis — some from the AI reading your code, some from you talking to it.

### Build
Pick forks, dispatch workers, review diffs, commit. Act by act. The codebase grows. The tree updates. New quests appear.

Same loop whether you're adding a feature, fixing a bug, or paying down tech debt.

---

## Core Concepts

### Skill Tree
The full decision graph for a project. Nodes are quests and forks. Edges are dependencies and consequences. The tree is never fully visible upfront — it grows as you build. Completing an act re-indexes the codebase and generates new quests that weren't visible before.

Like an RPG skill tree: you see the shape of the path ahead, but only unlock what you've earned.

### Acts
The tree is organized into dependency layers called **Acts**. Act 1 contains foundational decisions. Act 2 is generated from Act 1 choices. Each act is a natural review and commit boundary.

Acts use a **soft gate**: future acts are visible but locked (dimmed) until their dependencies resolve. You can see what you're building toward — locked nodes inform your current decisions — but you can only act on what's unlocked.

```
Act 1 — Foundation
  ├── [quest] Basic scaffold + ping-pong       ← unlocked
  ├── [fork]  Transport: REST | WebSocket      ← unlocked
  └── [fork]  Database: Postgres | None        ← unlocked
        ↓  Act 1 complete → re-index → Act 2 generated
Act 2 — Structure                              ← visible, locked
  ├── [quest] Schema design
  ├── [fork]  Auth strategy
  └── [quest] Route layout
        ↓
Act 3 — Features                               ← locked
  ...
```

### Quest
A unit of work in the skill tree. Quests come from three sources:

1. **Codebase analysis** — Metroscope indexes the project and surfaces architectural recommendations ("add incremental re-indexing", "abstract the parser behind a trait")
2. **User conversation** — Talk + Plan produces a quest ("add offline sync")
3. **AI suggestion** — orchestrator proposes quests based on what was just built

Every quest has:
- A title and description
- An act it belongs to
- Dependencies (what must be done first)
- What it unlocks downstream
- One or more forks (the decisions inside it)

### Fork
A decision point inside a quest. Each fork has:
- A question ("how should we handle auth?")
- 2-3 named options with downstream consequences visible before you choose
- A chat window to discuss tradeoffs with the AI
- A "Custom..." option
- A worker that executes the chosen option

Forks are where the human stays in control. Workers never decide — they implement.

### Fork Chat
Each fork has its own conversation thread. Before picking:
- "Why is option B better here?"
- "What does picking A lock me out of in Act 3?"
- "What would a senior engineer choose for a small team?"

Preferences expressed in fork chats inform the orchestrator's suggestions on future forks. The conversation is continuous — Talk doesn't end when the quest starts, it just gets progressively more focused.

### Worker
A short-lived AI session that implements a chosen fork. Multiple workers run in parallel — you navigate decisions at human speed while implementation catches up asynchronously. Workers output structured multi-file changes reviewed before being applied.

In the Claude Code integration, the worker *is* Claude Code itself — the MCP server dispatches work back to the active session.

### Orchestrator
A persistent background agent that owns the tree for a project. It:
- Reads the Metroscope index to understand what exists
- Generates quests from codebase analysis
- Structures Talk conversations into Plans and Quests
- Generates acts and computes dependencies
- Surfaces options and consequences for each fork
- Learns your preferences from fork chat history
- Detects conflicts between parallel workers
- Triggers re-indexing after act completion to generate new quests
- Runs **locally via Ollama** for ambient decisions — no API cost, no round-trips
- Escalates to the active Claude Code session when a human decision is needed

### Modes

**Co-pilot** — you drive, fork by fork. Chat at each decision, build N forks at a time, review as they complete.

**Autopilot** — hand remaining forks to the orchestrator. It resolves them based on your preferences so far, fires all workers, presents the full act diff for review. Switch from co-pilot to autopilot mid-session.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Metro Server                          │
│                                                              │
│  ┌─────────────────┐    ┌────────────────────────────────┐  │
│  │   Metroscope    │    │            Hayai               │  │
│  │                 │    │                                │  │
│  │  - Indexer      │───▶│  - Skill tree + acts           │  │
│  │  - Index store  │    │  - Orchestrator (Ollama)       │  │
│  │  - Map server   │    │  - Worker pool                 │  │
│  │  - Quest gen    │    │  - Fork chat                   │  │
│  └─────────────────┘    │  - Conflict detection          │  │
│                         │  - MCP server                  │  │
│                         └────────────────────────────────┘  │
└──────────────┬──────────────────────────────────────────────┘
               │  MCP (tools + events)
               │  WebSocket (tree, events, chat)
               │  SSE (worker streaming)
               │  HTTP (map queries)
    ┌──────────┴──────┬──────────────┐
    │  Claude Code    │  Neovim      │  VSCode...
    │  (primary)      │  (Lua)       │
    │                                │
    │  thin clients:                 │
    │  metro map + skill tree UI     │
    │  talk/plan chat                │
    │  fork picker + chat            │
    │  worker stream + diff review   │
    └────────────────────────────────┘
```

### Metro Server
Single binary (Go or Rust). One instance per project. Metroscope and Hayai live inside it as subsystems — they share the index, the same connections, and the same session.

Hayai exposes itself as an **MCP server**. Claude Code connects to it as an MCP client, giving Claude Code tools to query and update the skill tree mid-session.

### MCP Tools

```
// Tree state
get_tree()                              → full skill tree (acts, quests, forks)
get_quest(quest_id)                     → quest detail + forks + dependencies
get_context()                           → current act, active forks, pending decisions

// Decision flow
propose_fork(quest_id, question, options[])   → fork_id
resolve_fork(fork_id, chosen_option, reason)  → updates tree, unlocks downstream
escalate(fork_id, description)                → flags for human, pauses workers

// Work tracking
dispatch_worker(fork_id, instructions)        → worker_id
worker_done(worker_id, summary)               → triggers re-index, generates new quests
get_pending_escalations()                     → list of forks waiting on human

// Index bridge
query_index(question)    → targeted Metroscope lookup, returns relevant stations only
re_index()               → runs metroscope-indexer, updates quests from new index
```

### Hook Integration

```json
// .claude/settings.json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Edit|Write",
      "hooks": [{
        "type": "command",
        "command": "hayai notify-change --file $CLAUDE_TOOL_INPUT_FILE_PATH"
      }]
    }]
  }
}
```

File changes are the trigger. The MCP server receives a minimal signal (file path + change type), runs a relevance filter against active quests, and only wakes the orchestrator if something meaningful changed.

### Token Budget

The full index is never sent to any LLM. The MCP server maintains a hot `context.json`:

```json
{
  "current_act": 2,
  "active_quest": "add-offline-sync",
  "pending_forks": ["auth-strategy"],
  "recently_touched": ["serena.rs", "map.rs"],
  "open_questions": ["conflict between worker-3 and worker-5 on schema"]
}
```

Per orchestrator wake, the token budget is roughly:

```
context.json             ~200 tokens   always
relevant stations        ~300 tokens   only if diff intersects active quests
current fork state       ~150 tokens   only the active fork, not the whole tree
─────────────────────────────────────
total                    ~650 tokens   vs. full index at 50k+
```

`query_index(question)` is the escape hatch — Claude calls it only when it needs specific codebase context. The MCP server does a targeted lookup and returns only the relevant stations.

### Model Tiers

| Role | Model |
|------|-------|
| Ambient watching, relevance filtering, auto-resolve | Ollama (local, free) |
| Fork chat, planning, architectural decisions | Claude (in active session) |
| Worker — actual coding | Claude Code |

The backend is pluggable. Ollama is the default for background orchestration (no API cost, no round-trips). Escalations surface in the Claude Code session where you're already working.

### Shared Index (`.metro/`)
```
.metro/
├── index.json       ← Metroscope: stations, lines, summaries, connections
├── tree.json        ← Hayai: skill tree, acts, quests, fork states
├── context.json     ← Hayai: hot summary for cheap context injection
├── state.log        ← append-only event log (forks dispatched, done, rejected)
└── session.json     ← orchestrator conversation history (for session restore)
```

Metroscope writes comprehension into the index. Hayai writes decisions. Same directory, complementary layers.

### AI Backends
Pluggable:
- `ollama` — local models (qwen2.5-coder, deepseek-coder-v2), no API key, default for orchestrator
- `claude-cli` — enterprise login via `claude` binary, no API key
- `anthropic-api` — direct via `$ANTHROPIC_API_KEY`
- `openai` — OpenAI or compatible endpoint

---

## How It Works on Existing Codebases

Run indexer once → Metroscope reads the codebase, generates summaries at every level (function → module → system), and produces an initial quest list from codebase analysis.

Open a Claude Code session → `get_context()` is called at session start. You immediately know what act you're in, what forks are pending, what was last built. No "wait what was I doing" friction.

Talk to add your own → "I want to add offline sync." Plan it. It becomes a quest in Act 2 (because it depends on the data layer decisions in Act 1).

Build → pick forks, Claude Code implements, hooks fire, tree updates. The orchestrator watches in the background via Ollama, auto-resolving what it can and escalating what it can't.

For **bug fixing**: Talk describes the symptom. Orchestrator traces the call graph via Metroscope to locate likely causes. A hypothesis quest appears with forks for each theory. Workers implement and test each hypothesis. The confirmed fix becomes a single approved fork.

---

## UI

No dedicated UI is required to validate the loop. The skill tree lives in `tree.json`. The conversation in Claude Code *is* the fork chat. A minimal Neovim buffer rendering `context.json` is enough for the prototype.

The visual skill tree — RPG graph with locked/unlocked nodes, visual fork picker — is a later problem, and the Neovim rendering infrastructure from Metroscope already handles the hard parts.

**Build order:**
1. MCP server with `tree.json` — get the loop working
2. `get_context()` at session start — know where you are
3. Ollama background orchestrator — ambient watching + escalation
4. Neovim skill tree buffer — reuse `render.lua` patterns
5. Visual UI (VSCode / web) — distribution problem, not a validation problem

---

## State as History

The `.metro/` directory committed to the repo is the decision history of the project:
- Every architectural decision ever made
- The options that were considered and rejected
- The reasoning behind each choice (from fork chat)
- What's still undecided

Git blame tells you *what* changed. Metro tells you *why*.

A new team member opens the skill tree and sees not just the current codebase but the path that led here — every fork, every tradeoff, every quest completed. Better than any wiki.

---

## Prototype Status

A Neovim-only Lua prototype lives in `lua/hayai/`. It validates the fork picker → streaming worker → approve/reject flow without a backend server.

Metroscope's Rust backend (`crates/`) and Neovim plugin (`neovim/metroscope.nvim/`) implement the metro map and indexer.

Neither prototype implements the full unified vision. They are proofs of concept for their respective halves.

---

## What's Next

1. MCP server skeleton in Rust (new crate: `metroscope-hayai`)
2. `tree.json` schema + `context.json` hot summary
3. Core MCP tools: `get_context`, `propose_fork`, `resolve_fork`, `dispatch_worker`
4. Hook integration: `PostToolUse` → relevance filter → orchestrator wake
5. Ollama backend for background orchestrator
6. Talk → Plan → Quest flow (orchestrator conversation)
7. Neovim skill tree buffer (acts, quests, forks, locked/unlocked)
8. Autopilot mode
9. Re-index after act completion → new quest generation
10. Multi-file worker output
11. VSCode extension
12. Bug investigation mode (hypothesis tree)
