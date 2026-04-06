-- Entrypoint loaded by neovim's plugin runtime.
-- Users who call require("promptline").setup() themselves don't need this.
-- This file is intentionally minimal — no auto-setup, no default keymaps,
-- so the plugin is inert until the user calls setup().
if vim.g.loaded_promptline then
  return
end
vim.g.loaded_promptline = true
