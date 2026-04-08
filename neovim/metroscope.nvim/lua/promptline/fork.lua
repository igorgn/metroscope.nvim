-- fork.lua — decision-driven co-pilot
-- Cursor on a TODO block → hotkey → pick an option → agent implements it.

local M = {}

local backend = require("promptline.backend")
local ui = require("promptline.ui")

-- ─── Find TODO block under cursor ────────────────────────────────────────────
-- Walks up and down from the cursor line collecting contiguous -- TODO / --
-- comment lines. Returns { start_lnum, end_lnum, text } (1-based) or nil.

local function find_todo_block(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = cursor[1] -- 1-based
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local total = #lines

  local function is_comment(l)
    return l ~= nil and l:match("^%s*%-%-")
  end
  local function is_todo(l)
    return l ~= nil and l:match("^%s*%-%-%s*TODO")
  end

  -- cursor must be on or near a TODO comment
  local anchor = lnum
  if not is_todo(lines[anchor]) then
    -- look one line up and down
    if is_todo(lines[anchor - 1]) then
      anchor = anchor - 1
    elseif is_todo(lines[anchor + 1]) then
      anchor = anchor + 1
    else
      return nil
    end
  end

  -- walk up to find block start
  local start_lnum = anchor
  while start_lnum > 1 and is_comment(lines[start_lnum - 1]) do
    start_lnum = start_lnum - 1
  end

  -- walk down to find block end (stop at first non-comment line)
  local end_lnum = anchor
  while end_lnum < total and is_comment(lines[end_lnum + 1]) do
    end_lnum = end_lnum + 1
  end

  local block_lines = {}
  for i = start_lnum, end_lnum do
    table.insert(block_lines, lines[i])
  end

  return {
    start_lnum = start_lnum,
    end_lnum = end_lnum,
    text = table.concat(block_lines, "\n"),
  }
end

-- ─── Get file context ─────────────────────────────────────────────────────────
-- Sends the whole file so the agent understands what's already implemented.

local function get_file_context(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return table.concat(lines, "\n")
end

-- ─── Options picker ───────────────────────────────────────────────────────────
-- Shows a float with the options returned by Claude.
-- User picks with 1/2/3, then agent implements the chosen option.

local function show_options(options, on_pick)
  local W = 64
  local rows = { "  Pick an option:", "" }
  for i, opt in ipairs(options) do
    -- word-wrap each option line
    local prefix = string.format("  %d.  ", i)
    local text = prefix .. opt
    table.insert(rows, text)
    table.insert(rows, "")
  end
  table.insert(rows, "  <Esc> / q  cancel")

  local H = math.min(#rows + 2, math.floor(vim.o.lines * 0.5))
  local row = math.floor((vim.o.lines - H) / 2)
  local col = math.floor((vim.o.columns - W) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = W,
    height = H,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = "  fork — choose direction  ",
    title_pos = "center",
    footer = "  1/2/3: pick  q/<Esc>: cancel  ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true

  local function close()
    vim.api.nvim_win_close(win, true)
  end
  local opts = { buffer = buf, nowait = true, silent = true }

  for i = 1, #options do
    vim.keymap.set("n", tostring(i), function()
      close()
      on_pick(i, options[i])
    end, opts)
  end

  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

-- ─── Parse options from Claude response ──────────────────────────────────────
-- Claude returns numbered options. Extract them as a list of strings.
-- Expected format:
--   1. Short description of option
--   2. Another option
--   3. Third option

local function parse_options(text)
  local options = {}
  for line in text:gmatch("[^\n]+") do
    local opt = line:match("^%s*%d+[%.%)%:]%s*(.+)$")
    if opt then
      table.insert(options, opt)
    end
  end
  return options
end

-- ─── Main trigger ─────────────────────────────────────────────────────────────

function M.trigger(config)
  local buf = vim.api.nvim_get_current_buf()
  local block = find_todo_block(buf)

  if not block then
    vim.notify("fork: no TODO block found near cursor", vim.log.levels.WARN)
    return
  end

  local file_context = get_file_context(buf)
  local filetype = vim.bo[buf].filetype or "text"

  -- Phase 1: ask Claude to surface concrete options for this TODO
  local phase1_prompt = string.format(
    "You are a decision-driven coding assistant. "
      .. "The user is building a %s file and has a TODO block they need to resolve.\n\n"
      .. "TODO block:\n%s\n\n"
      .. "File context:\n```%s\n%s\n```\n\n"
      .. "List exactly 2-3 concrete implementation options for this TODO. "
      .. "Be specific — name the approach, not just a description. "
      .. "One line each. Numbered list. No explanations, no code yet.",
    filetype,
    block.text,
    filetype,
    file_context
  )

  vim.notify("fork: reading the fork…", vim.log.levels.INFO)

  local cfg = vim.tbl_extend("force", config, {
    system_prompt = "You are a precise coding assistant. Follow instructions exactly.",
  })

  backend.run(cfg, block.text, phase1_prompt, nil, function(result, err)
    vim.schedule(function()
      if err or not result or result == "" then
        vim.notify("fork: " .. (err or "empty response"), vim.log.levels.ERROR)
        return
      end

      local options = parse_options(result)
      if #options == 0 then
        vim.notify("fork: could not parse options from response", vim.log.levels.WARN)
        return
      end

      -- Phase 2: user picks, agent implements
      show_options(options, function(_, chosen)
        local phase2_prompt = string.format(
          "Implement this option for the TODO block in the file below.\n\n"
            .. "TODO block to replace:\n%s\n\n"
            .. "Chosen approach: %s\n\n"
            .. "File context:\n```%s\n%s\n```\n\n"
            .. "Return ONLY the replacement Lua comment block (-- lines). "
            .. "No code, no explanations, no markdown fences. "
            .. "The comment block should describe exactly what to implement, "
            .. "with enough detail that the next step can write the code.",
          block.text,
          chosen,
          filetype,
          file_context
        )

        vim.notify("fork: implementing…", vim.log.levels.INFO)

        backend.run(cfg, block.text, phase2_prompt, nil, function(impl, impl_err)
          vim.schedule(function()
            if impl_err or not impl or impl == "" then
              vim.notify("fork: " .. (impl_err or "empty response"), vim.log.levels.ERROR)
              return
            end

            -- Replace the TODO block with the refined comment
            local new_lines = vim.split(impl, "\n", { plain = true })
            vim.api.nvim_buf_set_lines(buf, block.start_lnum - 1, block.end_lnum, false, new_lines)

            vim.notify("fork: done — TODO refined, implement the code below it", vim.log.levels.INFO)
          end)
        end)
      end)
    end)
  end)
end

return M
