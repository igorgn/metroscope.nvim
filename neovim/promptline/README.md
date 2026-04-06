# promptline.nvim

AI-powered inline text editor for Neovim. Select code or text in visual mode, describe what you want, and the selection is replaced in-place. Press `u` to undo.
## Screenshots
Quickly get local explanation from any window, even claude
<img width="1122" height="716" alt="image" src="https://github.com/user-attachments/assets/976ad326-3ffb-4bbd-bc3a-95fd76f8dd5e" />

## Features

- Visual mode selection → float prompt → in-place replacement
- Native undo (`u`) — replacement is a single undo step
- LSP diagnostics automatically included in the prompt (no need to describe the error)
- LSP formatting applied after replacement, file saved automatically
- Preset mode selector with `<C-n>`/`<C-p>` — opens a side picker, `<Enter>` uses the selected mode's default prompt or whatever you typed
- **Explain mode** — shows the AI response in the float without touching your buffer
- Three backends: Claude CLI, Anthropic API, CopilotChat

## Requirements

- Neovim 0.9+
- One of:
  - [`claude`](https://claude.ai/code) CLI installed and logged in (`claude_cli` backend)
  - `ANTHROPIC_API_KEY` env var + `curl` (`anthropic_api` backend)
  - [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) installed (`copilot_chat` backend)

## Installation

### lazy.nvim

```lua
{
  "igorgn/promptline.nvim",
  config = function()
    require("promptline").setup()
  end,
}
```

### Local path (development)

```lua
{
  dir = "/path/to/promptline.nvim",
  config = function()
    require("promptline").setup()
  end,
}
```

## Usage

1. Select text in **Visual mode**
2. Press `<leader>p` (default keymap)
3. A float prompt appears:
   - Type a custom instruction and press `<Enter>`
   - Or press `<C-n>`/`<C-p>` to open the mode picker — a small window appears showing available presets, cycling highlights the active one
   - `<Enter>` with empty input uses the selected preset's default prompt
   - `<Esc>` or focusing another window cancels
4. A spinner shows in the float while the AI is working
5. **Edit mode**: selection replaced in-place, LSP formatting applied, file saved
6. **Explain mode**: result shown in the float — press `q` or `<Esc>` to close
7. Press `u` to undo any edit

## Default Presets

| Label   | Default prompt                      | Mode    |
|---------|-------------------------------------|---------|
| Fix     | Fix the issues in this code         | edit    |
| Improve | Improve this                        | edit    |
| Explain | Explain what this code does clearly | explain |

Presets are fully customizable — see Configuration below.

## Configuration

All options with their defaults:

```lua
require("promptline").setup({
  -- Backend to use for AI requests
  -- "claude_cli"    — uses the `claude` binary (existing Claude Code login, no API key needed)
  -- "anthropic_api" — calls the Anthropic REST API directly
  -- "copilot_chat"  — uses CopilotChat.nvim (requires the plugin to be installed)
  backend = "claude_cli",

  -- Model for the anthropic_api backend
  model = "claude-haiku-4-5",
  max_tokens = 8096,

  -- API key for anthropic_api backend (falls back to $ANTHROPIC_API_KEY env var)
  api_key = nil,

  -- Used when submitting with empty input and no preset selected
  default_prompt = "Improve this",

  -- System prompt for edit mode
  system_prompt = "You are a precise code and text editor. When given text and an instruction, you apply the instruction and return only the edited result.",

  -- Visual mode keymap that triggers the plugin
  keymap = "<leader>p",

  -- Width of the prompt float window
  float_width = 60,

  -- Run LSP formatter on the buffer after applying a change
  format_on_apply = true,

  -- Presets cycled with <C-n>/<C-p> in the prompt window.
  -- Selecting a preset sets the active mode; empty input uses its default prompt.
  -- Typing your own input overrides the preset prompt but keeps the mode.
  -- mode = "edit"    — replaces the selection with the AI response
  -- mode = "explain" — shows the AI response in the float without editing the buffer
  presets = {
    { label = "Fix",     prompt = "Fix the issues in this code",        mode = "edit" },
    { label = "Improve", prompt = "Improve this",                       mode = "edit" },
    { label = "Explain", prompt = "Explain what this code does clearly", mode = "explain" },
  },
})
```

## Examples

| Selection | Input | Result |
|-----------|-------|--------|
| Rust function with type error | `Fix` preset (LSP error auto-included) | Fixes the type error |
| Any code | `Make more idiomatic` | Rewrites using idiomatic patterns |
| Long function | `Split into smaller functions` | Refactors in-place |
| Paragraph | `Make concise` | Shortens while preserving meaning |
| Code block | `Explain` preset | Explanation shown in float, buffer untouched |

## Backends

### `claude_cli` (default)

Uses your existing Claude Code login — no API key required.

```lua
require("promptline").setup({
  backend = "claude_cli",
})
```

Requires the `claude` CLI to be installed and authenticated (`claude auth login`).

### `anthropic_api`

Calls the Anthropic API directly using `curl`.

```lua
require("promptline").setup({
  backend = "anthropic_api",
  model = "claude-sonnet-4-6",  -- or any Claude model
  -- api_key = "sk-ant-...",    -- or set ANTHROPIC_API_KEY env var
})
```

### `copilot_chat`

Uses CopilotChat.nvim — fast, uses your existing GitHub Copilot subscription.

```lua
require("promptline").setup({
  backend = "copilot_chat",
})
```

Requires [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) to be installed.
