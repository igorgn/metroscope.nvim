local M = {}

-- ─── State ────────────────────────────────────────────────────────────────────
-- This is what the watcher knows at any point in time.
-- You decide what to add here as you build.

M.state = {
  errors = {}, -- last collected errors: list of { lnum, message, code }
  context = nil, -- surrounding code snapshot at the time of error
  buf = nil, -- buffer where errors were last seen
  pending = false, -- true while we're waiting for the agent to respond
}

-- ─── Collect ──────────────────────────────────────────────────────────────────
-- Grab all ERROR-level diagnostics from the current buffer.
-- Build per-error snippet context using a fixed window (Option B):
--   for each diagnostic line, capture ±CONTEXT_LINES around it.
--
-- Implementation details:
--   1) Get only ERROR diagnostics with vim.diagnostic.get(buf, { severity = ERROR }).
--   2) Read all buffer lines once.
--   3) For each diagnostic, compute:
--        from = max(0, lnum - CONTEXT_LINES)
--        to   = min(last_line, lnum + CONTEXT_LINES)
--   4) Build a snippet line-by-line from [from..to], preserving order.
--   5) Prefix snippet lines with line numbers (1-based for display).
--   6) Mark the exact diagnostic line clearly (e.g. ">>>"), others unmarked.
--   7) Store snippet text with each error entry ({ lnum, message, code, snippet }).
--
-- Notes:
--   - Clamp snippet bounds to avoid out-of-range access.
--   - Keep diagnostics lnum internally 0-based; convert to 1-based only for display.
--   - If no ERROR diagnostics exist, return nil.

local CONTEXT_LINES = 4 -- lines above and below each error to capture

local function collect(buf)
  local diagnostics = vim.diagnostic.get(buf, { severity = vim.diagnostic.severity.ERROR })

  if #diagnostics == 0 then
    return nil -- nothing to do
  end

  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local errors = {}

  for _, d in ipairs(diagnostics) do
    local lnum = d.lnum -- 0-based

    -- Capture surrounding lines (clamp to buffer bounds)
    -- TODO: think about whether CONTEXT_LINES is the right amount
    local from = math.max(0, lnum - CONTEXT_LINES)
    local to = math.min(#all_lines - 1, lnum + CONTEXT_LINES)
    local snippet = {}
    for i = from, to do
      local marker = (i == lnum) and ">>>" or "   "
      table.insert(snippet, string.format("%s %d: %s", marker, i + 1, all_lines[i + 1] or ""))
    end

    table.insert(errors, {
      lnum = lnum + 1, -- convert to 1-based for display
      message = d.message,
      code = d.code,
      snippet = table.concat(snippet, "\n"),
    })
  end

  return errors
end

-- ─── Trigger ──────────────────────────────────────────────────────────────────
-- Called after each save. Collects errors and stores them in state.
-- Does NOT call the agent yet — that happens in M.suggest().
--
-- TODO: decide if you want to auto-call suggest() here after a timeout,
--   or always require the user to press the hotkey.
--   Auto-call is noisier but more "watchman" in spirit.
--   Start with hotkey-only — you can always add auto later.

local function on_save(buf)
  local errors = collect(buf)

  M.state.buf = buf
  M.state.errors = errors or {}

  -- Uncomment to see what you're collecting while building:
  -- if errors then
  --   vim.notify("watchman: " .. #errors .. " error(s) captured", vim.log.levels.INFO)
  -- end
end

-- ─── Suggest ──────────────────────────────────────────────────────────────────
-- Called by the user hotkey (or auto-trigger if you add it).
-- Takes the collected state and sends it to the Claude backend.
--
-- TODO: implement this once on_save() is working and you're happy
--   with the shape of M.state.errors.
--
-- Hint: backend.run() signature (from backend.lua):
--   M.run(config, selection, user_prompt, diagnostics, on_done)
--   "selection" here will be the code snippet, "diagnostics" the error messages.

function M.suggest(config)
  if #M.state.errors == 0 then
    vim.notify("watchman: no errors to explain", vim.log.levels.INFO)
    return
  end

  if M.state.pending then
    vim.notify("watchman: already thinking…", vim.log.levels.WARN)
    return
  end

  -- TODO: build the input for the backend from M.state.errors
  --   What do you send as "selection"? The snippets? The whole file?
  --   What do you send as "user_prompt"? "Explain these errors and suggest a fix"?
  --   These choices shape the quality of the suggestion.

  -- TODO: call backend.run() here
  -- TODO: display the result — look at how init.lua calls ui.show_explain()
end

-- ─── Setup ────────────────────────────────────────────────────────────────────
-- Call this from init.lua's M.setup() when watchman is enabled.
-- Registers the BufWritePost autocmd that drives the whole thing.

function M.setup(config)
  -- BufWritePost fires after every save in any buffer.
  -- We only care about the current file — check buftype to skip special buffers.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("promptline_watcher", { clear = true }),
    callback = function(ev)
      -- ev.buf is the buffer that was saved
      if vim.bo[ev.buf].buftype ~= "" then
        return
      end -- skip non-file buffers
      on_save(ev.buf)
    end,
  })

  -- TODO: register the suggest hotkey here, e.g.:
  --   vim.keymap.set("n", config.watchman.keymap or "<leader>w", function()
  --     M.suggest(config)
  --   end, { desc = "Watchman: suggest fix for current errors" })
end

return M
