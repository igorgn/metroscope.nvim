# Metroscope

Visualize a codebase as an interactive metro map. Navigate code like a city transit system — functions are stations, files are lines, you are always in the middle.

**Goal: comprehension, not generation.** The LLM runs once at index time, caches summaries at every abstraction level, and serves them instantly at query time.

```
[auth      ] ──●──────────────●──────────────◉──────────
                 authenticate   check_token    verify_jwt ← you are here

[db        ] ──●──────────────●─────────────────────────
                 connect        query
```

---

## How It Works

```
Neovim plugin  →  HTTP :7777  →  metroscope-server  →  .metroscope/index.json
                                                              ↑
                                                    metroscope-indexer
                                                    (tree-sitter + Claude API)
```

1. **Index once** — the indexer parses your codebase, calls Claude to generate summaries at function, file, and system level, and writes `.metroscope/index.json`
2. **Serve instantly** — the server loads the index and answers queries with no LLM calls
3. **Navigate** — the Neovim plugin sends your cursor position, renders the map, lets you explore

---

## Requirements

- Rust (for building the indexer and server)
- Neovim 0.10+
- An Anthropic API key (for indexing only)
- `uvx` (for optional Serena LSP enrichment)

---

## Installation

### 1. Build the binaries

```bash
git clone https://github.com/igorgn/metroscope
cd metroscope
cargo build --release

# Add to PATH or copy to somewhere on your PATH:
cp target/release/metroscope-indexer ~/.local/bin/
cp target/release/metroscope-server ~/.local/bin/
```

### 2. Install the Neovim plugin

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  dir = "/path/to/metroscope/neovim/metroscope.nvim",
  config = function()
    require("metroscope").setup({
      -- All options are optional
      server      = "http://127.0.0.1:7777",  -- default
      leader      = "<leader>m",               -- default: <leader>ms to open, <leader>mi to re-index
      module_info = "detailed",                -- "detailed" | "compact"
    })
  end,
}
```

### 3. Index your project

```bash
metroscope-indexer index /path/to/your/project --api-key $ANTHROPIC_API_KEY
```

This writes `.metroscope/index.json` into your project root. Takes ~1-2 minutes depending on codebase size.

### 4. Start the server

```bash
metroscope-server --index-path /path/to/your/project --port 7777
```

Keep this running in the background while you work.

---

## Usage

Open any file in your project and press `<leader>ms`. Metroscope opens on the module your current file belongs to, with the cursor on your current function.

### Navigation

**Map view (functions zoom):**

| Key | Action |
|-----|--------|
| `h` / `l` | move left/right along a line |
| `j` / `k` | switch between lines |
| `i` or `K` | info popup — summary, calls, callers |
| `I` | pin info popup (updates as you navigate) |
| `<Tab>` | move focus into info popup |
| `<CR>` | drill into station list for this line |
| `b` | go up to module map |
| `q` / `<Esc>` | close |

**Info popup:**

| Key | Action |
|-----|--------|
| `j` / `k` | move arrow cursor |
| `<CR>` | jump to file/line under cursor |
| `e` | open detailed explanation float |
| `<Tab>` | return focus to map |
| `q` / `<Esc>` | close popup |

**Station list (innermost zoom):**

| Key | Action |
|-----|--------|
| `j` / `k` | move through stations |
| `<Tab>` | move focus to preview |
| `<C-f>` / `<C-b>` | scroll preview |
| `e` | explanation float |
| `<CR>` | jump to code and close |
| `b` | back to function map |
| `q` / `<Esc>` | close |

### Re-indexing

After significant changes, re-index from inside Neovim:

```
<leader>mi
```

Or from the terminal:

```bash
metroscope-indexer index /path/to/project --api-key $ANTHROPIC_API_KEY
```

### Serena LSP enrichment (optional)

Adds accurate `CalledBy` connections using LSP instead of name-matching:

```bash
metroscope-indexer index /path/to/project --api-key $ANTHROPIC_API_KEY --serena-dir=yes
```

Requires `uvx` on PATH. Serena is fetched and run automatically.

---

## Supported Languages

Currently: **Rust**. TypeScript and Lua support planned.

---

## Project Structure

```
metroscope/
├── crates/
│   ├── metroscope-types/    # shared data model (Station, Line, Index)
│   ├── metroscope-indexer/  # CLI: parse + LLM summaries → index.json
│   └── metroscope-server/   # HTTP server: loads index, serves queries
└── neovim/
    └── metroscope.nvim/     # Lua plugin
```
