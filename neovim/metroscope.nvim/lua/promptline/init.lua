local M = {}

local ui = require("promptline.ui")
local backend = require("promptline.backend")
local replace = require("promptline.replace")
local fork = require("promptline.fork")
local metroscope = require("promptline.metroscope")

M.config = {
  backend = "claude_cli", -- "claude_cli" | "anthropic_api" | "copilot_chat"
  model = "claude-haiku-4-5",
  max_tokens = 8096,
  api_key = nil,
  default_prompt = "Improve this",
  default_mode = "edit", -- "edit" | "explain"
  system_prompt = "You are a precise code and text editor. When given text and an instruction, you apply the instruction and return only the edited result.",
  keymap = "<leader>p",
  float_width = 60,
  format_on_apply = true,
  -- Presets are modes cycled with <C-n>/<C-p>.
  -- The selected preset's prompt is used when the input is left empty.
  -- Typing in the input overrides the preset prompt entirely.
  presets = {
    { label = "Fix", prompt = "Fix the issues in this code", mode = "edit" },
    { label = "Improve", prompt = "Improve this", mode = "edit" },
    { label = "Explain", prompt = "Explain what this code does clearly", mode = "explain" },
  },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_set_hl(0, "PromptlineDim", { bg = "#000000", fg = "#000000" })

  vim.keymap.set("v", M.config.keymap, function()
    M.trigger()
  end, { desc = "Promptline: edit selection with AI" })

  local fork_keymap = (opts and opts.fork_keymap) or "<leader>f"
  vim.keymap.set("n", fork_keymap, function()
    fork.trigger(M.config)
  end, { desc = "Promptline: resolve TODO fork under cursor" })
end

local function get_visual_selection()
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)

  local buf = vim.api.nvim_get_current_buf()
  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  local start_line = start_pos[1]
  local start_col = start_pos[2]
  local end_line = end_pos[1]
  local end_col = end_pos[2]

  local lines = vim.api.nvim_buf_get_text(buf, start_line - 1, start_col, end_line - 1, end_col + 1, {})
  local text = table.concat(lines, "\n")

  local diag_lines = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local dline = d.lnum + 1
    if dline >= start_line and dline <= end_line then
      local severity = vim.diagnostic.severity[d.severity] or "HINT"
      table.insert(diag_lines, string.format("  line %d [%s]: %s", dline, severity, d.message))
    end
  end

  local metro_context = metroscope.fetch_context(buf, start_line)

  return {
    buf = buf,
    start_line = start_line,
    start_col = start_col,
    end_line = end_line,
    end_col = end_col + 1,
    text = text,
    diagnostics = #diag_lines > 0 and table.concat(diag_lines, "\n") or nil,
    metro_context = metro_context,
  }
end

function M.trigger()
  local sel = get_visual_selection()

  if sel.text == "" then
    vim.notify("promptline: no text selected", vim.log.levels.WARN)
    return
  end

  -- Highlight the selection while the float is open
  local hl_ns = vim.api.nvim_create_namespace("promptline_selection")
  for line = sel.start_line - 1, sel.end_line - 1 do
    local start_col = (line == sel.start_line - 1) and sel.start_col or 0
    local line_len = #(vim.api.nvim_buf_get_lines(sel.buf, line, line + 1, false)[1] or "")
    local end_col = (line == sel.end_line - 1) and math.min(sel.end_col, line_len) or line_len
    vim.api.nvim_buf_set_extmark(sel.buf, hl_ns, line, start_col, {
      end_row = line,
      end_col = end_col,
      hl_group = "Visual",
    })
  end
  local function clear_hl()
    vim.api.nvim_buf_clear_namespace(sel.buf, hl_ns, 0, -1)
  end

  local default_preset_idx = 1
  for i, p in ipairs(M.config.presets) do
    if p.mode == M.config.default_mode then
      default_preset_idx = i
      break
    end
  end

  ui.prompt({
    title = "promptline",
    placeholder = M.config.default_prompt,
    width = M.config.float_width,
    presets = M.config.presets,
    default_preset_idx = default_preset_idx,
  }, function(submission, float_win, float_buf)
    local preset = M.config.presets[submission.preset_idx]
    local mode = (preset and preset.mode) or M.config.default_mode

    -- Typed text takes priority; fall back to selected preset's prompt, then default
    local user_prompt = submission.text
    if user_prompt == "" then
      user_prompt = (preset and preset.prompt) or M.config.default_prompt
    end

    local cfg = M.config
    if mode == "explain" then
      cfg = vim.tbl_extend("force", M.config, {
        system_prompt = "You are a helpful code assistant. Explain the provided code clearly and concisely.",
      })
    end

    local stop_spinner = ui.show_working(float_win, float_buf, "thinking…")

    backend.run(cfg, sel.text, user_prompt, sel.diagnostics, sel.metro_context, function(result, err)
      vim.schedule(function()
        stop_spinner()
        clear_hl()

        if err then
          ui.close_float(float_win)
          vim.notify("promptline error: " .. err, vim.log.levels.ERROR)
          return
        end

        if not result or result == "" then
          ui.close_float(float_win)
          vim.notify("promptline: empty response", vim.log.levels.WARN)
          return
        end

        if mode == "explain" then
          ui.show_explain(float_win, float_buf, result)
        else
          ui.close_float(float_win)
          replace.replace_selection(sel.buf, sel.start_line, sel.start_col, sel.end_line, sel.end_col, result)

          if M.config.format_on_apply then
            vim.lsp.buf.format({ bufnr = sel.buf, async = false })
          end

          vim.api.nvim_buf_call(sel.buf, function()
            vim.cmd("silent! write")
          end)

          vim.notify("promptline: done  (u to undo)", vim.log.levels.INFO)
        end
      end)
    end)
  end, function()
    -- on_cancel
    clear_hl()
  end)
end

return M
