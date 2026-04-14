local M = {}

local ui = require("promptline.ui")
local backend = require("promptline.backend")
local replace = require("promptline.replace")
local fork = require("promptline.fork")
local metroscope = require("promptline.metroscope")
local session = require("promptline.session")

M.config = {
  backend = "copilot_chat", -- "claude_cli" | "anthropic_api" | "copilot_chat"
  model = "auto",
  max_tokens = 8096,
  api_key = nil,
  default_prompt = "Help me with this",
  default_mode = "edit", -- "edit" | "explain" | "chat"
  system_prompt = "You are a precise code and text editor. When given text and an instruction, you apply the instruction and return only the edited result.",
  keymap = "<leader>p",
  float_width = 60,
  format_on_apply = true,
  presets = {
    { label = "Fix",     prompt = "Fix the issues in this code",         mode = "edit" },
    { label = "Explain", prompt = "Explain what this code does clearly", mode = "explain" },
    {
      label = "Tutor",
      prompt = "Walk me through this step by step",
      mode = "chat",
      system_prompt = "You are a patient programming tutor. Explain concepts clearly, use examples, and check for understanding.",
    },
    {
      label = "Critic",
      prompt = "What are the weaknesses here?",
      mode = "chat",
      system_prompt = "You are a rigorous code reviewer. Point out bugs, design problems, and missed edge cases without sugarcoating.",
    },
    {
      label = "Finish",
      prompt = "Complete the implementation",
      mode = "chat",
      system_prompt = "You are a code completion assistant. Given partial code, complete it following the existing style and conventions. Return only the completed code, no commentary.",
    },
  },
  session = {
    reset_keymap  = "<leader>sr",
    context_lines = 10,
  },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_set_hl(0, "PromptlineDim", { bg = "#000000", fg = "#000000" })

  vim.keymap.set("v", M.config.keymap, function()
    M.trigger()
  end, { desc = "Promptline: edit selection with AI" })

  vim.keymap.set("n", M.config.keymap, function()
    M.trigger()
  end, { desc = "Promptline: open at cursor" })

  local fork_keymap = (opts and opts.fork_keymap) or "<leader>f"
  vim.keymap.set("n", fork_keymap, function()
    fork.trigger(M.config)
  end, { desc = "Promptline: resolve TODO fork under cursor" })

  session.setup(M.config)
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
    is_visual = true,
  }
end

local function get_cursor_context()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] -- 1-based
  local n = M.config.session.context_lines
  local start_line = math.max(1, row - n)
  local end_line = math.min(vim.api.nvim_buf_line_count(buf), row + n)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)

  local diag_lines = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local dline = d.lnum + 1
    if dline >= start_line and dline <= end_line then
      local sev = vim.diagnostic.severity[d.severity] or "HINT"
      table.insert(diag_lines, string.format("  line %d [%s]: %s", dline, sev, d.message))
    end
  end

  return {
    buf = buf,
    -- stub selection fields so replace path doesn't crash if somehow reached
    start_line = row,
    start_col = 0,
    end_line = row,
    end_col = 0,
    text = table.concat(lines, "\n"),
    diagnostics = #diag_lines > 0 and table.concat(diag_lines, "\n") or nil,
    metro_context = metroscope.fetch_context(buf, row),
    is_visual = false,
  }
end

function M.trigger()
  local vmode = vim.api.nvim_get_mode().mode
  local ctx
  if vmode == "v" or vmode == "V" or vmode == "\22" then
    ctx = get_visual_selection()
  else
    ctx = get_cursor_context()
  end

  if ctx.is_visual and ctx.text == "" then
    vim.notify("promptline: no text selected", vim.log.levels.WARN)
    return
  end

  -- Highlight the selection while the float is open (visual mode only)
  local hl_ns = vim.api.nvim_create_namespace("promptline_selection")
  if ctx.is_visual then
    for line = ctx.start_line - 1, ctx.end_line - 1 do
      local start_col = (line == ctx.start_line - 1) and ctx.start_col or 0
      local line_len = #(vim.api.nvim_buf_get_lines(ctx.buf, line, line + 1, false)[1] or "")
      local end_col = (line == ctx.end_line - 1) and math.min(ctx.end_col, line_len) or line_len
      vim.api.nvim_buf_set_extmark(ctx.buf, hl_ns, line, start_col, {
        end_row = line,
        end_col = end_col,
        hl_group = "Visual",
      })
    end
  end
  local function clear_hl()
    vim.api.nvim_buf_clear_namespace(ctx.buf, hl_ns, 0, -1)
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

    local user_prompt = submission.text
    if user_prompt == "" then
      user_prompt = (preset and preset.prompt) or M.config.default_prompt
    end

    if mode == "chat" then
      local sess = session.get(ctx.buf, preset.label)
      if sess.pending then
        vim.notify("promptline: request in progress", vim.log.levels.WARN)
        ui.close_float(float_win)
        clear_hl()
        return
      end
      sess.pending = true

      local cfg = vim.tbl_extend("force", M.config, {
        system_prompt = (preset and preset.system_prompt) or M.config.system_prompt,
      })

      local turn = ctx.text .. "\n\nQuestion: " .. user_prompt
      session.append_user(ctx.buf, preset.label, turn)
      local history = session.get_history(ctx.buf, preset.label)

      local stop_spinner = ui.show_working(float_win, float_buf, "thinking…")

      backend.run(cfg, ctx.text, user_prompt, ctx.diagnostics, ctx.metro_context, function(result, err)
        vim.schedule(function()
          sess.pending = false
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

          if vim.api.nvim_buf_is_valid(ctx.buf) then
            session.append_assistant(ctx.buf, preset.label, result)
            ui.show_explain(float_win, float_buf, result)
          end
        end)
      end, history)

      return
    end

    -- edit / explain modes
    local cfg = M.config
    if mode == "explain" then
      cfg = vim.tbl_extend("force", M.config, {
        system_prompt = "You are a helpful code assistant. Explain the provided code clearly and concisely.",
      })
    end

    local stop_spinner = ui.show_working(float_win, float_buf, "thinking…")

    backend.run(cfg, ctx.text, user_prompt, ctx.diagnostics, ctx.metro_context, function(result, err)
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
          replace.replace_selection(ctx.buf, ctx.start_line, ctx.start_col, ctx.end_line, ctx.end_col, result)

          if M.config.format_on_apply then
            vim.lsp.buf.format({ bufnr = ctx.buf, async = false })
          end

          vim.api.nvim_buf_call(ctx.buf, function()
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
