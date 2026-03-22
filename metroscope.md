# Metroscope

A code comprehension tool that visualizes a codebase as an interactive metro map.

**Goal:** "Help me understand" — not "write code for me."
Navigate code like a city metro. Functions are stations. Modules are lines. You are always in the middle of the map.

---

## The Idea

Most AI coding tools are built around *generation*. Metroscope is built around *comprehension*.

Instead of asking "how is this written?", Metroscope answers:
- "What does this function do?"
- "What calls it? What does it call?"
- "What module is this part of, and what does that module do?"
- "Where does this fit in the whole system?"

The LLM runs at **index time** — it reads the codebase once, generates summaries at every abstraction level, and caches everything. At query time, explanations are instant.

---

## Architecture

```
┌─────────────────────────────┐
│  Neovim plugin (Lua)        │  thin client — sends cursor pos, renders map
│  metroscope.nvim            │
└──────────────┬──────────────┘
               │ HTTP (localhost:7777)
┌──────────────▼──────────────┐
│  Map Server (Rust/axum)     │  loads index, serves queries instantly, no LLM
│  metroscope-server          │
└──────────────┬──────────────┘
               │ reads .metroscope/index.json
┌──────────────▼──────────────┐
│  Indexer (Rust CLI)         │  tree-sitter parse + LLM summaries → index
│  metroscope-indexer         │  runs once on demand, user triggers re-index
└─────────────────────────────┘
```

The server is **editor-agnostic** — any editor can talk to it via HTTP. VSCode, Cursor, JetBrains — all can use the same backend.

---

## The Metro Map

```
[auth      ] ──●──────────────●──────────────◉──────────
                 authenticate   check_token    verify_jwt

[db        ] ──●──────────────●─────────────────────────
                 connect        query
```

- **Stations** (`●`) = functions
- **Lines** = modules / files
- **Colors** = different layers of the system
- **◉** = where you are right now
- **You are always in the middle** — the map centers on your current position

### Navigation (vim-native)

| Key | Action |
|-----|--------|
| `h` / `l` | move left/right along a line |
| `j` / `k` | switch to adjacent line |
| `Enter` | jump to code |
| `K` | popup: plain-English summary |
| `o` | show all connections |
| `gh` | highlight path from entry point to here |
| `<C-o>` | go back |
| `q` | close map |

---

## Data Model

**Station** (smallest unit = function):
```
id:          "examples/06_axum_hello.rs::health"
name:        "health"
kind:        Function
location:    { file, line_start, line_end }
summary:     "Returns a 200 OK response to confirm the server is running."
connections: [{ to: "main", kind: CalledBy }]
line_id:     "examples/06_axum_hello.rs"
```

**Line** (module = file for POC):
```
id:       "examples/06_axum_hello.rs"
name:     "axum_hello"
color:    "#E84B3A"
summary:  "A basic Axum HTTP server demonstrating routing, extractors, and handlers."
stations: ["health", "get_agent", "echo", "main", ...]
```

**Index** (persisted to `.metroscope/index.json`):
```
project_root:   "/path/to/project"
created_at:     1234567890
system_summary: "A structured Rust learning course covering async/web fundamentals."
stations:       { ... }
lines:          { ... }
entry_points:   ["main"]
```

---

## Abstraction Levels

```
System          "A structured Rust learning course"
  └── Module    "Basic Axum HTTP server demonstrating routing"
        └── Function   "Returns 200 OK to confirm server is running"   ← cursor
```

All three levels are pre-computed and cached at index time. The user navigates up and down this tree freely.

---

## POC Scope

- **Language:** Rust only
- **Editor:** Neovim only (server is editor-agnostic, other editors deferred)
- **Index:** on-demand, manual trigger — no real-time updates
- **LLM:** Claude API (`claude-haiku-4-5`) at index time only
- **Storage:** JSON (`.metroscope/index.json` in project root)

**Not in POC:**
- Breadcrumb trail / visited station dimming
- Git history context ("why does this exist")
- Multi-language support
- VSCode / other editor plugins
- Real-time index updates

---

## POC Success Criteria

Open any `.rs` file → cursor on a function → press `<leader>ms` → metro map opens with that function highlighted → navigate to an unfamiliar function → press `K` → read its purpose in plain English → understand where it fits in the system.

**All without reading a single line of code.**

---

## Workspace Structure

```
metroscope/
├── Cargo.toml                     # workspace
├── crates/
│   ├── metroscope-types/          # shared data model
│   ├── metroscope-indexer/        # CLI: parse + LLM + write index
│   └── metroscope-server/         # HTTP: load index + serve queries
└── neovim/
    └── metroscope.nvim/           # Lua plugin
```

---

## Usage

```bash
# Index a project (runs once, triggers LLM)
metroscope-indexer index /path/to/project --api-key $ANTHROPIC_API_KEY

# Start the server
metroscope-server --index-path /path/to/project --port 7777

# In Neovim: open map at cursor
<leader>ms

# Re-index after major changes
<leader>mi
```

