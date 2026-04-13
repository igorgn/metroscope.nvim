-- session.lua — in-buffer chat with persistent history
-- Trigger with <C-/> on a comment line. Response renders as virtual text below.
-- Prefix with "-- DO:" to activate edit mode (replaces code below comment).
-- PLAN.md in cwd is loaded once as system prompt context.
-- Treesitter provides breadcrumb + symbol name so the model can use its
-- own Serena MCP tools for caller/callee lookups if needed.

local M = {}

local ns = vim.api.nvim_create_namespace("promptline_session")

-- { [buf] = { history, marks, plan_loaded, plan_content, pending } }
local sessions = {}

local SCOPE_TYPES = {
  function_definition = true,
  local_function = true,
  function_declaration = true,
  method_definition = true,
  ["function"] = true,
  arrow_function = true,
  class_definition = true,
  class_declaration = true,
  module = true,
  method = true,
  function_item = true,
  impl_item = true,
  struct_item = true,
}

-- ── helpers ──────────────────────────────────────────────────────────────────

local function get_session(buf)
  if not sessions[buf] then
    sessions[buf] = { history = {}, marks = {}, plan_loaded = false, plan_content = nil, pending = false }
  end
  return sessions[buf]
end

-- Extract first identifier/name child text from a treesitter node
local function node_name(node, buf)
  for child in node:iter_children() do
    local t = child:type()
    if t == "identifier" or t == "name" or t == "property_identifier" then
      local sr, sc, er, ec = child:range()
      local lines = vim.api.nvim_buf_get_lines(buf, sr, er + 1, false)
      if lines and lines[1] then
        return lines[1]:sub(sc + 1, ec)
      end
    end
  end
  return nil
end

-- Returns breadcrumb string, innermost signature line, innermost symbol name
-- All three may be nil if treesitter is unavailable or cursor is outside a scope.
local function get_ts_context(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  row = row - 1 -- 0-indexed

  local ok, parser = pcall(vim.treesitter.get_parser, buf, vim.bo[buf].filetype)
  if not ok or not parser then return nil, nil, nil end

  local tree = parser:parse()[1]
  if not tree then return nil, nil, nil end

  local root = tree:root()
  local node = root:named_descendant_for_range(row, col, row, col)
  if not node then return nil, nil, nil end

  local scopes = {}
  local innermost_name = nil
  local innermost_sig = nil
  local current = node

  while current do
    if SCOPE_TYPES[current:type()] then
      local name = node_name(current, buf)
      if name then
        table.insert(scopes, 1, name)
        if not innermost_name then
          innermost_name = name
          local sr = current:range() -- returns sr, sc, er, ec
          local sig_lines = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)
          innermost_sig = sig_lines and sig_lines[1] or nil
        end
      end
    end
    current = current:parent()
  end

  if #scopes == 0 then return nil, nil, nil end

  local buf_name = vim.api.nvim_buf_get_name(buf)
  local filename = vim.fn.fnamemodify(buf_name, ":t:r")
  local breadcrumb = filename .. " > " .. table.concat(scopes, " > ")

  return breadcrumb, innermost_sig, innermost_name
end

-- Load PLAN.md once per session, cache result
local function load_plan(config, sess)
  if sess.plan_loaded then return sess.plan_content end
  sess.plan_loaded = true
  local path = vim.fn.getcwd() .. "/" .. (config.session.plan_path or "PLAN.md")
  local f = io.open(path, "r")
  if not f then
    sess.plan_content = nil
    return nil
  end
  sess.plan_content = f:read("*a")
  f:close()
  return sess.plan_content
end

-- Extract comment text and mode from the cursor line.
-- Returns {text, is_edit, line_0idx} or nil.
local function extract_comment(buf, config)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
  local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
  if not lines or not lines[1] then return nil end
  local line = lines[1]

  local edit_prefix = config.session.edit_prefix or "-- DO:"

  -- Edit mode prefix first
  local edit_text = line:match("^%s*" .. vim.pesc(edit_prefix) .. "%s*(.*)")
  if edit_text and edit_text ~= "" then
    return { text = edit_text, is_edit = true, line_0idx = row }
  end

  -- Standard comment prefixes
  for _, pat in ipairs({ "^%s*%-%-+%s*(.*)", "^%s*//+%s*(.*)", "^%s*#+%s*(.*)", "^%s*;+%s*(.*)" }) do
    local text = line:match(pat)
    if text and text ~= "" then
      return { text = text, is_edit = false, line_0idx = row }
    end
  end

  return nil
end

-- Find the code block below comment_line_0idx to replace in edit mode.
-- Returns {start_line, end_line, end_col} (1-indexed) or nil.
local function find_edit_target(buf, comment_line_0idx)
  local total = vim.api.nvim_buf_line_count(buf)
  local i = comment_line_0idx + 1 -- start scanning line after comment (0-indexed)

  -- Skip blank lines immediately below the comment
  while i < total do
    local l = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or ""
    if l:match("%S") then break end
    i = i + 1
  end

  if i >= total then return nil end

  local start_line = i + 1 -- convert to 1-indexed
  local end_line = i
  local j = i

  while j < total do
    local l = vim.api.nvim_buf_get_lines(buf, j, j + 1, false)[1] or ""
    if l == "" or l:match("^%s*%-%-") or l:match("^%s*//") or l:match("^%s*#") then
      break
    end
    end_line = j
    j = j + 1
  end

  local end_content = vim.api.nvim_buf_get_lines(buf, end_line, end_line + 1, false)[1] or ""
  return { start_line = start_line, end_line = end_line + 1, end_col = #end_content }
end

-- Render AI response as virtual text below line_0idx.
-- Returns list of extmark IDs added.
local function render_response(buf, line_0idx, text)
  local ids = {}
  local lines = vim.split(text, "\n", { plain = true })

  -- blank line before
  local id0 = vim.api.nvim_buf_set_extmark(buf, ns, line_0idx, 0, {
    virt_lines = { { { "", "PromptlineSession" } } },
    virt_lines_above = false,
  })
  table.insert(ids, id0)

  for _, l in ipairs(lines) do
    local id = vim.api.nvim_buf_set_extmark(buf, ns, line_0idx, 0, {
      virt_lines = { { { "  ", "PromptlineSessionDim" }, { l, "PromptlineSession" } } },
      virt_lines_above = false,
    })
    table.insert(ids, id)
  end

  -- blank line after
  local id_end = vim.api.nvim_buf_set_extmark(buf, ns, line_0idx, 0, {
    virt_lines = { { { "", "PromptlineSession" } } },
    virt_lines_above = false,
  })
  table.insert(ids, id_end)

  return ids
end

-- Build the user turn content string
local function build_turn_content(comment_text, breadcrumb, sig, symbol_name, buf_name, ctx_lines, diagnostics)
  local parts = {}

  -- Structured location context for the model (used directly or for Serena lookups)
  local file_rel = vim.fn.fnamemodify(buf_name, ":.")
  table.insert(parts, "[context]")
  table.insert(parts, "file: " .. file_rel)
  if symbol_name then
    table.insert(parts, "symbol: " .. symbol_name)
  end
  if breadcrumb then
    table.insert(parts, "breadcrumb: " .. breadcrumb)
  end
  if sig then
    table.insert(parts, "signature: " .. vim.trim(sig))
  end

  if ctx_lines and ctx_lines ~= "" then
    table.insert(parts, "\n[code around cursor]\n" .. ctx_lines)
  end

  if diagnostics and #diagnostics > 0 then
    local diag_strs = {}
    for _, d in ipairs(diagnostics) do
      local sev = vim.diagnostic.severity[d.severity] or "HINT"
      table.insert(diag_strs, string.format("  line %d [%s]: %s", d.lnum + 1, sev, d.message))
    end
    table.insert(parts, "\n[diagnostics]\n" .. table.concat(diag_strs, "\n"))
  end

  table.insert(parts, "\n[question]\n" .. comment_text)

  return table.concat(parts, "\n")
end

-- ── public API ────────────────────────────────────────────────────────────────

function M.reset(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  sessions[buf] = nil
end

function M.trigger(config)
  local buf = vim.api.nvim_get_current_buf()
  local sess = get_session(buf)

  if sess.pending then
    vim.notify("promptline session: already waiting for a response", vim.log.levels.WARN)
    return
  end

  local comment = extract_comment(buf, config)
  if not comment then
    vim.notify("promptline session: cursor is not on a non-empty comment line", vim.log.levels.WARN)
    return
  end

  local plan_content = load_plan(config, sess)
  local breadcrumb, sig, symbol_name = get_ts_context(buf)

  -- Context lines around cursor
  local n = config.session.context_lines or 10
  local row = comment.line_0idx
  local ctx_start = math.max(0, row - n)
  local ctx_end = math.min(vim.api.nvim_buf_line_count(buf), row + n + 1)
  local ctx_lines_tbl = vim.api.nvim_buf_get_lines(buf, ctx_start, ctx_end, false)
  local ctx_lines = table.concat(ctx_lines_tbl, "\n")

  -- LSP diagnostics near cursor
  local all_diag = vim.diagnostic.get(buf)
  local near_diag = {}
  for _, d in ipairs(all_diag) do
    if math.abs(d.lnum - row) <= n then
      table.insert(near_diag, d)
    end
  end

  local buf_name = vim.api.nvim_buf_get_name(buf)
  local turn_content = build_turn_content(
    comment.text, breadcrumb, sig, symbol_name, buf_name, ctx_lines, near_diag
  )

  -- Show spinner
  local spinner_id = vim.api.nvim_buf_set_extmark(buf, ns, comment.line_0idx, 0, {
    virt_lines = { { { "  ⋯", "PromptlineSessionDim" } } },
    virt_lines_above = false,
  })

  sess.pending = true
  table.insert(sess.history, { role = "user", content = turn_content })

  -- Build config for this call
  local sess_config = vim.tbl_extend("force", config, {
    session_system_prompt = plan_content,
  })

  local backend = require("promptline.backend")
  backend.run(sess_config, ctx_lines, turn_content, near_diag, nil, function(result, err)
    vim.schedule(function()
      sess.pending = false

      -- Clear spinner
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, spinner_id)

      if not vim.api.nvim_buf_is_valid(buf) then return end

      if err then
        vim.notify("promptline session error: " .. tostring(err), vim.log.levels.ERROR)
        -- remove the user turn we added
        table.remove(sess.history)
        return
      end

      if not result or result == "" then
        vim.notify("promptline session: empty response", vim.log.levels.WARN)
        table.remove(sess.history)
        return
      end

      table.insert(sess.history, { role = "assistant", content = result })

      if comment.is_edit then
        local target = find_edit_target(buf, comment.line_0idx)
        if target then
          local replace = require("promptline.replace")
          replace.replace_selection(buf, target.start_line, 0, target.end_line, target.end_col, result)
          if config.format_on_apply then
            vim.lsp.buf.format({ bufnr = buf, async = false })
          end
          vim.api.nvim_buf_call(buf, function() vim.cmd("silent! write") end)
          vim.notify("promptline session: edit applied (u to undo)", vim.log.levels.INFO)
        else
          -- Fallback: no code below comment, render as virt text
          local ids = render_response(buf, comment.line_0idx, result)
          for _, id in ipairs(ids) do table.insert(sess.marks, id) end
        end
      else
        local ids = render_response(buf, comment.line_0idx, result)
        for _, id in ipairs(ids) do table.insert(sess.marks, id) end
      end
    end)
  end, sess.history)
end

function M.setup(config)
  vim.api.nvim_set_hl(0, "PromptlineSession",    { fg = "#7aa2f7", italic = true })
  vim.api.nvim_set_hl(0, "PromptlineSessionDim", { fg = "#565f89" })

  local keymap = config.session.keymap or "<C-/>"
  local reset_keymap = config.session.reset_keymap or "<leader>sr"

  vim.keymap.set("n", keymap, function()
    M.trigger(config)
  end, { desc = "Promptline session: ask AI at comment" })

  vim.keymap.set("n", reset_keymap, function()
    local buf = vim.api.nvim_get_current_buf()
    M.reset(buf)
    vim.notify("promptline session: history cleared", vim.log.levels.INFO)
  end, { desc = "Promptline session: reset history + clear virtual text" })

  -- Clear stale extmarks when buffer is reloaded
  vim.api.nvim_create_autocmd("BufReadPost", {
    callback = function(ev)
      if sessions[ev.buf] then
        M.reset(ev.buf)
      end
    end,
  })
end

return M
