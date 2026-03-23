# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build everything
cargo build

# Build release binaries
cargo build --release

# Run a specific crate's binary
cargo run -p metroscope-indexer -- index /path/to/project --api-key $ANTHROPIC_API_KEY
cargo run -p metroscope-server -- --index-path /path/to/project --port 7777

# Index with Serena LSP call graph enrichment (uses uvx, no local install needed)
cargo run -p metroscope-indexer -- index /path/to/project --serena-dir=yes

# Check without building binaries
cargo check

# There are no automated tests yet.
```

## Architecture

Metroscope is a **code comprehension tool** — LLM runs at index time, not query time.

```
Neovim plugin (Lua)  →  HTTP localhost:7777  →  metroscope-server (Rust/axum)
                                                        │
                                                 reads .metroscope/index.json
                                                        │
                                              metroscope-indexer (Rust CLI)
                                              tree-sitter + Claude API → index
```

**Three Rust crates:**
- `metroscope-types` — shared data model (`Station`, `Line`, `Index`, `Location`). Everything serializes to `.metroscope/index.json`.
- `metroscope-indexer` — CLI that parses Rust files with tree-sitter, calls Claude API in batches (haiku model) to generate per-function `summary` (1 sentence) and `explanation` (2-4 sentences), plus file-level and system-level summaries. Optionally enriches the call graph via Serena MCP.
- `metroscope-server` — axum HTTP server, loads the index at startup, serves four endpoints with no LLM calls.

**Server endpoints:**
- `GET /map?file=<rel>&line=<n>&crate=<id>` — map view; returns `MapResponse` with `focused_station`, `focused_crate`, `lines[]`, `project_root`
- `GET /module-map` — crate-level module view
- `GET /station/*id` — full station detail including `explanation`, resolved `calls`/`called_by`
- `GET /connections?file=<id>` — cross-file connection summary

**Neovim plugin** (`neovim/metroscope.nvim/lua/metroscope/`) is split into focused modules:

| Module | Responsibility |
|--------|---------------|
| `state.lua` | Shared `state` table, `config`, layout constants |
| `render.lua` | Box drawing, `render_map`, `render_module_map` |
| `highlights.lua` | Highlight group setup and extmark application |
| `window.lua` | `open_dim_win` (background dim), `open_window` (main float) |
| `info.lua` | Info popup, explain float, `show_info` |
| `stations.lua` | Station list zoom level (list + preview panels) |
| `navigation.lua` | `move_*`, `current_station/module`; injected `redraw_fn` to avoid circular deps |
| `init.lua` | Thin orchestrator: `M.open/close/setup/index`, keymaps, zoom transitions |

## Key Design Decisions

**Zoom levels (3):** modules → functions (per-crate) → stations (list+preview). Each is a separate view. `b` goes up, `<CR>` goes down. `state.zoom` tracks current level: `"modules"` | `"functions"` | `"stations"`.

**`M.open()` startup logic:** fetches `/map?file=&line=` to get `focused_crate`, then immediately fetches `/map?crate=<id>` to open that crate's function view with cursor on the current function. Falls back to module map if no file or unknown crate.

**Map window is hidden (not closed) when entering station list** — `nvim_win_hide` keeps it alive; `nvim_win_show` + `nvim_set_current_win` restores it on `b`. Preview buffer is replaced on every j/k navigation; keymaps are stored in `state.sl_prev_keymaps` and re-applied by `sl_update_preview` on each swap.

**Info popup positioning** uses `relative="win", win=state.win` so it moves with the map window. Column offset is computed from `focused_box_right_col()` which sums box widths.

**`crate_id_of(file_id)`** in `map.rs` extracts the crate from a path like `crates/<name>/src/...`. Files outside `crates/` return `"root"`.

**Serena integration** (`serena.rs`): spawned via `uvx --from git+https://github.com/oraios/serena` over stdio MCP. Adds `CalledBy` connections to stations. The `--serena-dir` flag is a presence-only opt-in; the value is ignored.

**Index persistence:** `.metroscope/index.json` in the project root. The `explanation` field was added after the initial POC — old indexes won't have it; re-index to generate.

## Lua LSP Warnings

All `undefined-global vim` warnings in the Lua files are false positives — the Neovim runtime injects `vim` globally. Ignore them.
