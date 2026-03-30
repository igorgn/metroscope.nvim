-- metroscope.nvim — thin orchestrator
-- Visualize a codebase as an interactive metro map.

local st       = require("metroscope.state")
local render   = require("metroscope.render")
local hl       = require("metroscope.highlights")
local win_mod  = require("metroscope.window")
local info_mod = require("metroscope.info")
local nav      = require("metroscope.navigation")
local sl_mod   = require("metroscope.stations")

local state  = st.state
local config = st.config
local ROWS_PER_LINE = st.ROWS_PER_LINE

local M = {}

-- ─── HTTP ─────────────────────────────────────────────────────────────────────

local function fetch(url)
  local handle = io.popen('curl -s --max-time 2 "' .. url .. '"')
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  if not result or result == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, result)
  return ok and decoded or nil
end

-- ─── Redraw ───────────────────────────────────────────────────────────────────

local function redraw()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  hl.setup()
  local rendered = state.zoom == "modules"
    and render.render_module_map(state.data)
    or  render.render_map(state.data)

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, rendered)
  vim.bo[state.buf].modifiable = false

  local target = (state.line_idx - 1) * ROWS_PER_LINE + 2
  local max_lines = vim.api.nvim_buf_line_count(state.buf)
  target = math.min(target, math.max(1, max_lines))
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, { target, 0 })
  end

  hl.apply()

  if state.info_pinned then
    vim.schedule(function()
      info_mod.show_info(nav.current_station, nav.current_module, M.close)
    end)
  end
end

-- Wire redraw back into navigation module
nav.set_redraw(redraw)

-- ─── Zoom helpers ─────────────────────────────────────────────────────────────

local function zoom_to_modules()
  local data = fetch(config.server .. "/module-map")
  if not data then
    vim.notify("Metroscope: could not fetch module map", vim.log.levels.ERROR)
    return
  end
  state.zoom         = "modules"
  state.data         = data
  state.crate_filter = nil
  state.line_idx     = 1
  state.station_idx  = 1
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_config(state.win, {
      footer     = "  i:info  <CR>:components  j/k:move  q:close  ",
      footer_pos = "center",
    })
  end
  redraw()
end

local function zoom_to_functions(crate_id)
  local url  = config.server .. "/map?crate=" .. vim.uri_encode(crate_id)
  local data = fetch(url)
  if not data then return end
  state.zoom         = "functions"
  state.data         = data
  state.crate_filter = crate_id
  state.line_idx     = 1
  state.station_idx  = 1
  if data.project_root then state.project_root = data.project_root end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_config(state.win, {
      footer     = "  i:info  <CR>:stations  h/l:move  j/k:line  b:modules  q:close  ",
      footer_pos = "center",
    })
  end
  redraw()
end

-- ─── Keymaps ──────────────────────────────────────────────────────────────────

local function set_keymaps(buf)
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  map("h", nav.move_left)
  map("l", nav.move_right)
  map("j", nav.move_down)
  map("k", nav.move_up)

  map("i", function()
    info_mod.show_info(nav.current_station, nav.current_module, M.close)
  end)
  map("K", function()
    info_mod.show_info(nav.current_station, nav.current_module, M.close)
  end)
  map("I", function()
    state.info_pinned = not state.info_pinned
    if state.info_pinned then
      info_mod.show_info(nav.current_station, nav.current_module, M.close)
      vim.notify("Metroscope: info pinned — navigating updates info panel", vim.log.levels.INFO)
    else
      info_mod.close_info()
    end
  end)
  map("<Tab>", function()
    if info_mod.info_win and vim.api.nvim_win_is_valid(info_mod.info_win) then
      vim.api.nvim_set_current_win(info_mod.info_win)
    end
  end)

  map("b", function()
    if state.zoom == "functions" then
      zoom_to_modules()
    end
  end)
  map("<CR>", function()
    if state.zoom == "modules" then
      local m = state.data and state.data.modules and state.data.modules[state.line_idx]
      if m then zoom_to_functions(m.id) end
    elseif state.zoom == "functions" then
      local line = state.data and state.data.lines and state.data.lines[state.line_idx]
      if line and #line.stations > 0 then
        sl_mod.zoom_to_stations(line, M.close)
      end
    end
  end)

  map("q",     M.close)
  map("<Esc>", M.close)
end

-- ─── Public API ───────────────────────────────────────────────────────────────

function M.close()
  state.info_pinned = false
  info_mod.close_info()
  sl_mod.close_station_list()
  if state.dim_win and vim.api.nvim_win_is_valid(state.dim_win) then
    vim.api.nvim_win_close(state.dim_win, true)
  end
  state.dim_win = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.buf  = nil
  state.win  = nil
  state.zoom = "functions"
end

function M.open()
  local file = vim.fn.expand("%:.")
  local line = vim.fn.line(".")

  -- Determine if current buffer has a real file
  local has_file = file ~= "" and vim.bo.buftype == ""

  local url = has_file
    and (config.server .. "/map?file=" .. vim.uri_encode(file) .. "&line=" .. line)
    or  (config.server .. "/map")

  local data = fetch(url)
  if not data then
    vim.notify("Metroscope: server not reachable at " .. config.server, vim.log.levels.ERROR)
    return
  end

  state.project_root = data.project_root or vim.fn.getcwd()

  hl.setup()
  state.dim_win        = win_mod.open_dim_win()
  state.buf, state.win = win_mod.open_window()
  set_keymaps(state.buf)

  -- If we know which crate the current file belongs to, open that crate's
  -- function view directly. Otherwise fall back to the module map.
  if has_file and type(data.focused_crate) == "string" and data.focused_crate ~= "root" then
    -- Drill straight into the crate, then position cursor on the focused station
    local crate_url  = config.server .. "/map?crate=" .. vim.uri_encode(data.focused_crate)
    local crate_data = fetch(crate_url)
    if crate_data then
      state.data         = crate_data
      state.zoom         = "functions"
      state.crate_filter = data.focused_crate
      state.line_idx     = 1
      state.station_idx  = 1
      if crate_data.project_root then state.project_root = crate_data.project_root end

      -- Position cursor on focused station within the crate view
      if data.focused_station then
        for li, ld in ipairs(crate_data.lines or {}) do
          for si, s in ipairs(ld.stations) do
            if s.id == data.focused_station then
              state.line_idx    = li
              state.station_idx = si
            end
          end
        end
      end

      vim.api.nvim_win_set_config(state.win, {
        footer     = "  i:info  <CR>:stations  h/l:move  j/k:line  b:modules  q:close  ",
        footer_pos = "center",
      })
      redraw()
      return
    end
  end

  -- Fallback: module map (no file, unknown crate, or crate fetch failed)
  local mod_data = fetch(config.server .. "/module-map")
  if mod_data then
    state.data         = mod_data
    state.zoom         = "modules"
    state.crate_filter = nil
    state.line_idx     = 1
    state.station_idx  = 1
    vim.api.nvim_win_set_config(state.win, {
      footer     = "  i:info  <CR>:components  j/k:move  q:close  ",
      footer_pos = "center",
    })
    redraw()
  end
end

-- Open directly into the station list for the current file's line,
-- skipping the function map view entirely.
function M.open_stations()
  local file = vim.fn.expand("%:.")
  local line = vim.fn.line(".")
  local has_file = file ~= "" and vim.bo.buftype == ""
  if not has_file then
    vim.notify("Metroscope: no file in current buffer", vim.log.levels.WARN)
    return
  end

  local url  = config.server .. "/map?file=" .. vim.uri_encode(file) .. "&line=" .. line
  local data = fetch(url)
  if not data then
    vim.notify("Metroscope: server not reachable at " .. config.server, vim.log.levels.ERROR)
    return
  end

  state.project_root = data.project_root or vim.fn.getcwd()

  -- Need crate data to find the focused line
  if not (type(data.focused_crate) == "string" and data.focused_crate ~= "root") then
    vim.notify("Metroscope: current file has no known crate — use <leader>ms instead", vim.log.levels.WARN)
    return
  end

  local crate_url  = config.server .. "/map?crate=" .. vim.uri_encode(data.focused_crate)
  local crate_data = fetch(crate_url)
  if not crate_data then
    vim.notify("Metroscope: could not fetch crate map", vim.log.levels.ERROR)
    return
  end

  state.data         = crate_data
  state.zoom         = "functions"
  state.crate_filter = data.focused_crate
  if crate_data.project_root then state.project_root = crate_data.project_root end

  -- Find the line that contains the focused station
  local target_line_idx = 1
  if data.focused_station then
    for li, ld in ipairs(crate_data.lines or {}) do
      for _, s in ipairs(ld.stations) do
        if s.id == data.focused_station then
          target_line_idx = li
          break
        end
      end
    end
  end
  state.line_idx    = target_line_idx
  state.station_idx = 1

  -- Open map window (hidden immediately — stations view takes over)
  hl.setup()
  state.dim_win        = win_mod.open_dim_win()
  state.buf, state.win = win_mod.open_window()
  set_keymaps(state.buf)

  local target_line = crate_data.lines and crate_data.lines[target_line_idx]
  if not target_line or #target_line.stations == 0 then
    -- Fallback: show the map normally
    vim.api.nvim_win_set_config(state.win, {
      footer     = "  i:info  <CR>:stations  h/l:move  j/k:line  b:modules  q:close  ",
      footer_pos = "center",
    })
    redraw()
    return
  end

  sl_mod.zoom_to_stations(target_line, M.close)
end

function M.index(project_root, api_key)
  project_root = project_root or vim.fn.getcwd()
  api_key      = api_key or vim.env.ANTHROPIC_API_KEY or ""
  local cmd = string.format(
    "metroscope-indexer index %s --api-key %s",
    vim.fn.shellescape(project_root),
    vim.fn.shellescape(api_key)
  )
  if config.serena_dir then
    cmd = cmd .. " --serena-dir " .. vim.fn.shellescape(config.serena_dir)
  end
  local p = config.prompts or {}
  if p.functions then cmd = cmd .. " --function-prompt " .. vim.fn.shellescape(p.functions) end
  if p.file      then cmd = cmd .. " --file-prompt "     .. vim.fn.shellescape(p.file)      end
  if p.system    then cmd = cmd .. " --system-prompt "   .. vim.fn.shellescape(p.system)    end
  vim.cmd("botright 15split | terminal " .. cmd)
end

function M.open_quests()
  local handle = io.popen('curl -s --max-time 4 "' .. config.server .. '/quests"')
  if not handle then
    vim.notify("Metroscope: could not reach server", vim.log.levels.ERROR)
    return
  end
  local result = handle:read("*a")
  handle:close()
  if not result or result == "" then
    vim.notify("Metroscope: no response from server", vim.log.levels.ERROR)
    return
  end
  local ok, quests = pcall(vim.json.decode, result)
  if not ok or type(quests) ~= "table" then
    vim.notify("Metroscope: failed to parse quests", vim.log.levels.ERROR)
    return
  end
  if #quests == 0 then
    vim.notify("Metroscope: no quests — re-index to generate", vim.log.levels.WARN)
    return
  end

  -- Highlight groups
  vim.api.nvim_set_hl(0, "MetroscopeQuestEasy",   { fg = "#22c55e", bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeQuestMedium", { fg = "#f59e0b", bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeQuestHard",   { fg = "#ef4444", bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeQuestTitle",  { fg = "#f1f5f9", bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeQuestComp",   { fg = "#64748b" })
  vim.api.nvim_set_hl(0, "MetroscopeQuestWhy",    { fg = "#94a3b8" })

  local W = 68
  local util = require("metroscope.util")

  -- Build rows + highlight metadata
  local rows = {}
  local hl_marks = {} -- { line (0-based), hl_group }

  local function push(text, hl)
    table.insert(rows, text)
    if hl then hl_marks[#rows] = hl end
  end

  push("  Architectural Quests", "MetroscopeQuestTitle")
  push(string.rep("─", W - 2))
  push("")

  for i, q in ipairs(quests) do
    local diff_hl = q.difficulty == "easy" and "MetroscopeQuestEasy"
               or  q.difficulty == "hard"  and "MetroscopeQuestHard"
               or  "MetroscopeQuestMedium"
    local badge = q.difficulty == "easy" and "[Easy]" or q.difficulty == "hard" and "[Hard]" or "[Medium]"
    push("  " .. badge .. "  " .. (q.component or "system"), diff_hl)
    push("  " .. (q.title or ""), "MetroscopeQuestTitle")
    for _, wl in ipairs(util.word_wrap(q.why or "", W - 4)) do
      push("  " .. wl, "MetroscopeQuestWhy")
    end
    if i < #quests then
      push("")
      push(string.rep("╌", W - 2), "MetroscopeQuestComp")
      push("")
    end
  end
  push("")

  local H = math.min(#rows + 2, math.floor(vim.o.lines * 0.75))
  local erow = math.floor((vim.o.lines - H) / 2)
  local ecol = math.floor((vim.o.columns - W) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("metroscope_quests")
  for lnum, hl in pairs(hl_marks) do
    vim.api.nvim_buf_add_highlight(buf, ns, hl, lnum - 1, 0, -1)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative   = "editor",
    width      = W,
    height     = H,
    row        = erow,
    col        = ecol,
    style      = "minimal",
    border     = "rounded",
    title      = "  ⚔ Quests  ",
    title_pos  = "center",
    footer     = "  j/k:scroll  q/<Esc>:close  ",
    footer_pos = "center",
    zindex     = 150,
  })
  vim.wo[win].wrap = true

  local opts = { buffer = buf, nowait = true, silent = true }
  local function close() vim.api.nvim_win_close(win, true) end
  vim.keymap.set("n", "q",     close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

function M.setup(opts)
  opts = opts or {}
  if opts.server      then config.server      = opts.server      end
  if opts.serena_dir  then config.serena_dir  = opts.serena_dir  end
  if opts.module_info then config.module_info = opts.module_info end
  if opts.prompts     then config.prompts     = opts.prompts     end
  local leader = opts.leader or "<leader>m"
  vim.keymap.set("n", leader .. "s", M.open,          { desc = "Metroscope: open map" })
  vim.keymap.set("n", leader .. "l", M.open_stations, { desc = "Metroscope: open station list for current file" })
  vim.keymap.set("n", leader .. "q", M.open_quests,   { desc = "Metroscope: show architectural quests" })
  vim.keymap.set("n", leader .. "e", function()
    local url = config.server .. "/export/svg"
    local open_cmd = vim.fn.has("mac") == 1 and "open" or "xdg-open"
    vim.fn.jobstart({ open_cmd, url }, { detach = true })
    vim.notify("Metroscope: opening export in browser…", vim.log.levels.INFO)
  end, { desc = "Metroscope: export SVG diagram" })
  vim.keymap.set("n", leader .. "i", function()
    M.index(vim.fn.getcwd(), vim.env.ANTHROPIC_API_KEY)
  end, { desc = "Metroscope: re-index" })
end

return M
