# promptline.nvim — Developer Notes

## Workflow instructions

When the user says **"looks good"**, run:
```
jj describe -m'<concise summary of the changes made in this session>'
```
Write the summary yourself based on what was built or changed. Keep it short (one line, imperative mood, e.g. `add preset cycling with C-n/C-p`).


## Project structure

```
lua/promptline/
  init.lua      — public API: setup(), trigger(), visual selection capture, orchestration
  ui.lua        — float window: prompt input, preset cycling, spinner, explain display
  backend.lua   — AI backends: claude_cli, anthropic_api, copilot_chat
  replace.lua   — buffer text replacement (single undo step via nvim_buf_set_text)
  fork.lua      — decision-driven co-pilot: cursor on TODO block → pick option → agent refines
  watcher.lua   — background error watcher: collects diagnostics on save, surfaces suggestions
plugin/
  promptline.lua — runtime guard (sets vim.g.loaded_promptline), no auto-setup
```

## Architecture

The plugin is intentionally kept to small focused files with no dependencies beyond Neovim's built-in APIs and optional external tools (claude CLI, curl, CopilotChat.nvim).

**Flow:**
1. `init.lua:trigger()` — captures visual selection + LSP diagnostics before opening the float (opening a float exits visual mode and clears `'<`/`'>` marks)
2. `ui.lua:prompt()` — opens the input float, handles preset cycling, calls `on_submit({ prompt, mode }, win, buf)`
3. `init.lua` — calls `ui.show_working()` to convert the prompt float into a spinner, then calls `backend.run()`
4. `backend.lua` — runs the AI request async via `vim.fn.jobstart` (CLI/curl) or CopilotChat Lua API, calls `on_done(result, err)`
5. `init.lua` — on result: either calls `ui.show_explain()` (explain mode) or `replace.replace_selection()` + format + save (edit mode)

## Key implementation notes

**Visual selection capture** (`init.lua:get_visual_selection`)
- Must feed `<Esc>` to update `'<`/`'>` marks before reading them
- `nvim_buf_get_text` end_col is exclusive; mark end_col is inclusive — so pass `end_col + 1`
- `replace.lua` clamps end_col to line length to avoid out-of-range errors when selection ends at EOL

**Undo**
- Replacement uses `nvim_buf_set_text` which is a single undo step — `u` just works, no custom undo handling

**Async**
- All backends use `vim.fn.jobstart` (non-blocking) or CopilotChat's async `ask()`
- Results are delivered via `vim.schedule()` to safely update the UI from a callback

**Float lifecycle**
- Prompt float stays open during the backend call (repurposed as a spinner)
- `WinLeave` autocmd closes and cancels if the user focuses another window
- `submitted` flag prevents double-cancel

**LSP diagnostics**
- Collected at selection time via `vim.diagnostic.get(buf)`, filtered to the selected line range
- Appended to the prompt so the model knows about errors without the user having to describe them

**After edit**
- `vim.lsp.buf.format` (sync) runs if `format_on_apply = true`
- `silent! write` saves the file, which triggers LSP file watchers and refreshes diagnostics

## Fork — decision-driven co-pilot

`fork.lua` implements a navigation model where the user steers, the agent drives.

**Flow:**
1. Cursor on/near a `-- TODO` comment block → `<leader>f` (configurable via `fork_keymap`)
2. `fork.trigger()` extracts the contiguous comment block (all `--` lines around the TODO)
3. Sends TODO block + file context to Claude — asks for 2-3 concrete named options (no code yet)
4. User picks `1`/`2`/`3` from a float picker
5. Claude replaces the TODO block with a refined, specific comment describing exactly what to implement
6. User is now at the next decision point or ready to implement

**Design intent:** the user makes decisions at forks; the agent implements between forks. The human is the architect, the agent is the builder. Each TODO is a fork — a decision point that requires judgment. Obvious stretches are delegated; forks are owned by the human.

**TODO block detection:** contiguous `-- comment` lines containing at least one `-- TODO`. Cursor must be on or within one line of a `-- TODO` line.

**Context sent to Claude:** currently the full file. Future improvement: use Serena MCP to send only the enclosing function's symbol (cheaper, more focused).

## Watcher — background error collector

`watcher.lua` fires on every `BufWritePost`, collects ERROR-level diagnostics, and stores them with surrounding code context in `M.state`. The user can then press a hotkey to ask Claude for a fix suggestion.

**Setup:** call `require("promptline.watcher").setup(config)` from `init.lua`'s `M.setup()`. Wire a keymap to `M.suggest(config)`.

**State shape:**
```lua
M.state = {
  errors  = {},     -- list of { lnum, message, code, snippet }
  buf     = nil,    -- buffer where errors were last seen
  pending = false,  -- true while waiting for agent response
}
```

**`suggest()` is not yet implemented** — the TODO block in `watcher.lua` is the next fork to resolve.

## Adding a new backend

1. Add a `run_<name>` function in `backend.lua` with signature:
   ```lua
   function M.run_mybackend(config, selection, user_prompt, diagnostics, on_done)
     -- call on_done(result_string, nil) on success
     -- call on_done(nil, error_string) on failure
   end
   ```
2. Add the dispatch case in `M.run()`
3. Document the new `backend = "mybackend"` option in README.md

## Adding a new mode

Modes are set per-preset via `mode = "..."`. Currently: `"edit"` and `"explain"`.

To add a new mode:
1. Handle it in `init.lua` in the `backend.run` callback (after the `if mode == "explain"` block)
2. Add a `show_<mode>` function in `ui.lua` if it needs a custom display
3. Optionally override `system_prompt` in `cfg` for the mode (as done for `explain`)

## Preset system

Presets live in `config.presets` as `{ label, prompt, mode }` tables. In the UI:
- First `<C-n>`/`<C-p>` press expands the float and shows the list
- Selecting a preset writes its `prompt` text into the input field (editable)
- `mode` is tracked separately from the input text — editing the text doesn't change the mode
- Submitting reads the current input text (possibly edited) and the last-selected mode
