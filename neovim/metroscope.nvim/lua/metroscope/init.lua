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

-- ─── Quest counts ─────────────────────────────────────────────────────────────

local function fetch_quest_counts()
  local quests = fetch(config.server .. "/quests")
  if not quests or type(quests) ~= "table" then return end
  local counts = {}
  for _, q in ipairs(quests) do
    local comp = q.component or "system"
    counts[comp] = (counts[comp] or 0) + 1
  end
  state.quest_counts = counts
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
        sl_mod.zoom_to_stations(line, M.close, M.explain_off)
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
  M.explain_off()
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

  fetch_quest_counts()

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
  M.explain_off()
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

  fetch_quest_counts()

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
  M.explain_off()
  local quests = fetch(config.server .. "/quests")
  if not quests or type(quests) ~= "table" then
    vim.notify("Metroscope: could not fetch quests", vim.log.levels.ERROR)
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

  -- quest_lines[i] = 1-based row of the quest header (badge line), for cursor tracking
  local quest_lines = {}

  local function build_rows(cursor_idx)
    local rows = {}
    local hl_marks = {}
    local function push(text, hl_group)
      table.insert(rows, text)
      if hl_group then hl_marks[#rows] = hl_group end
    end

    push("  Architectural Quests", "MetroscopeQuestTitle")
    push(string.rep("─", W - 2))
    push("")

    for i, q in ipairs(quests) do
      local diff_hl = q.difficulty == "easy" and "MetroscopeQuestEasy"
                 or  q.difficulty == "hard"  and "MetroscopeQuestHard"
                 or  "MetroscopeQuestMedium"
      local badge = q.difficulty == "easy" and "[Easy]" or q.difficulty == "hard" and "[Hard]" or "[Medium]"
      local arrow = (i == cursor_idx) and "▶ " or "  "
      quest_lines[i] = #rows + 1  -- row this quest starts on (1-based)
      push(arrow .. badge .. "  " .. (q.component or "system"), diff_hl)
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
    return rows, hl_marks
  end

  local cursor_idx = 1
  local ns_q = vim.api.nvim_create_namespace("metroscope_quests")

  local function render_into(buf, rows, hl_marks)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns_q, 0, -1)
    for lnum, hl_group in pairs(hl_marks) do
      vim.api.nvim_buf_add_highlight(buf, ns_q, hl_group, lnum - 1, 0, -1)
    end
  end

  local rows, hl_marks = build_rows(cursor_idx)

  local H = math.min(#rows + 2, math.floor(vim.o.lines * 0.75))
  local erow = math.floor((vim.o.lines - H) / 2)
  local ecol = math.floor((vim.o.columns - W) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  render_into(buf, rows, hl_marks)

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
    footer     = "  j/k:move  x:execute  q/<Esc>:close  ",
    footer_pos = "center",
    zindex     = 70,
  })
  vim.wo[win].wrap = true

  local opts = { buffer = buf, nowait = true, silent = true }
  local function close() vim.api.nvim_win_close(win, true) end

  local function move(delta)
    local new_idx = math.max(1, math.min(#quests, cursor_idx + delta))
    if new_idx == cursor_idx then return end
    cursor_idx = new_idx
    local r, h = build_rows(cursor_idx)
    render_into(buf, r, h)
    local target_row = quest_lines[cursor_idx] or 1
    vim.api.nvim_win_set_cursor(win, { target_row, 0 })
  end

  local function execute_quest()
    local q = quests[cursor_idx]
    if not q then return end

    local prompt = string.format(
      "Implement this architectural improvement for the %s component:\n\n%s\n\n%s",
      q.component or "system", q.title or "", q.why or ""
    )
    prompt = prompt:gsub("'", "'\\''")
    local flag = (q.difficulty == "hard") and " --plan" or ""

    local has_jj  = vim.fn.executable("jj")  == 1
    local has_git = vim.fn.executable("git") == 1

    -- Build workspace options for the picker
    local choices = { "1. Run in current directory" }
    if has_git then table.insert(choices, "2. Create git worktree") end
    if has_jj  then table.insert(choices, (has_git and "3" or "2") .. ". Create jj workspace") end
    table.insert(choices, "")
    table.insert(choices, "  <Esc>/q to cancel")

    local pick_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[pick_buf].buftype   = "nofile"
    vim.bo[pick_buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(pick_buf, 0, -1, false, choices)
    vim.bo[pick_buf].modifiable = false

    local W2 = 40
    local H2 = #choices
    local pick_win = vim.api.nvim_open_win(pick_buf, true, {
      relative   = "editor",
      width      = W2,
      height     = H2,
      row        = math.floor((vim.o.lines - H2) / 2),
      col        = math.floor((vim.o.columns - W2) / 2),
      style      = "minimal",
      border     = "rounded",
      title      = "  Launch workspace  ",
      title_pos  = "center",
      zindex     = 75,
    })

    local function pick_close() vim.api.nvim_win_close(pick_win, true) end

    local function launch(work_dir)
      local claude_args = { "claude" }
      if flag ~= "" then table.insert(claude_args, "--plan") end
      table.insert(claude_args, prompt)
      close()
      vim.cmd("botright 20split")
      vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
      vim.fn.termopen(claude_args, { cwd = work_dir or state.project_root or vim.fn.getcwd() })
      vim.notify("Metroscope: launching quest — " .. (q.title or ""), vim.log.levels.INFO)
    end

    local function make_slug()
      local s = (q.title or "quest"):lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
      return s:sub(1, 30)
    end

    local popts = { buffer = pick_buf, nowait = true, silent = true }

    vim.keymap.set("n", "1", function()
      pick_close()
      launch(nil)
    end, popts)

    if has_git then
      vim.keymap.set("n", "2", function()
        pick_close()
        local slug = make_slug()
        local branch = "quest/" .. slug
        local parent   = vim.fn.expand("~") .. "/quest-worktrees"
        local worktree = parent .. "/" .. slug
        local setup
        if vim.fn.isdirectory(worktree) == 1 then
          setup = "echo '--- reusing existing worktree ---'"
        else
          setup = string.format(
            "mkdir -p %s && git -C %s worktree add -b %s %s 2>&1 && echo '--- worktree ready ---'",
            vim.fn.shellescape(parent),
            vim.fn.shellescape(state.project_root or vim.fn.getcwd()),
            vim.fn.shellescape(branch),
            vim.fn.shellescape(worktree)
          )
        end
        local result = vim.fn.system(setup)
        if vim.v.shell_error ~= 0 then
          vim.notify("Metroscope: git worktree failed:\n" .. result, vim.log.levels.ERROR)
          return
        end
        launch(worktree)
      end, popts)
    end

    if has_jj then
      local jj_key = (has_git and "3") or "2"
      vim.keymap.set("n", jj_key, function()
        pick_close()
        local slug = make_slug()
        local parent  = vim.fn.expand("~") .. "/quest-worktrees"
        local workspace = parent .. "/" .. slug
        -- If workspace dir already exists, reuse it; otherwise create it
        local setup
        if vim.fn.isdirectory(workspace) == 1 then
          setup = "echo '--- reusing existing workspace ---'"
        else
          setup = string.format(
            "mkdir -p %s && jj -R %s workspace add %s 2>&1 && echo '--- workspace ready ---'",
            vim.fn.shellescape(parent),
            vim.fn.shellescape(state.project_root or vim.fn.getcwd()),
            vim.fn.shellescape(workspace)
          )
        end
        local result = vim.fn.system(setup)
        if vim.v.shell_error ~= 0 then
          vim.notify("Metroscope: jj workspace failed:\n" .. result, vim.log.levels.ERROR)
          return
        end
        launch(workspace)
      end, popts)
    end

    vim.keymap.set("n", "q",     pick_close, popts)
    vim.keymap.set("n", "<Esc>", pick_close, popts)
  end

  vim.keymap.set("n", "j",     function() move(1)  end, opts)
  vim.keymap.set("n", "k",     function() move(-1) end, opts)
  vim.keymap.set("n", "x",     execute_quest, opts)
  vim.keymap.set("n", "q",     close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

-- ─── Explain mode: live float that follows the cursor ────────────────────────

local explain_augroup = vim.api.nvim_create_augroup("MetroscopeExplain", { clear = true })
local explain_mode_on = false

local function explain_update()
  if not explain_mode_on then return end

  local file = vim.fn.expand("%:.")
  local line = vim.fn.line(".")

  -- On non-file buffers (e.g. the float itself), do nothing
  if file == "" or vim.bo.buftype ~= "" then return end

  local map = fetch(config.server .. "/map?file=" .. vim.uri_encode(file) .. "&line=" .. line)
  local station_id = map and type(map.focused_station) == "string" and map.focused_station

  if not station_id then
    -- Empty line or unindexed — show blank float
    info_mod.open_explain_float(nil, nil)
    return
  end

  -- Same station already shown — skip the fetch
  if info_mod.explain_station_id == station_id then return end

  local station_name = station_id:match("::([^:]+)$") or station_id
  info_mod.open_explain_float(station_id, station_name)
end

function M.explain_off()
  if not explain_mode_on then return end
  explain_mode_on = false
  vim.api.nvim_clear_autocmds({ group = explain_augroup })
  info_mod.close_explain()
end

function M.peek()
  if explain_mode_on then
    M.explain_off()
    vim.notify("Metroscope: explain mode off", vim.log.levels.INFO)
  else
    explain_mode_on = true
    vim.api.nvim_create_autocmd("CursorMoved", {
      group    = explain_augroup,
      pattern  = "*",
      callback = explain_update,
    })
    explain_update()
    vim.notify("Metroscope: explain mode on", vim.log.levels.INFO)
  end
end

function M.setup(opts)
  opts = opts or {}
  if opts.server      then config.server      = opts.server      end
  if opts.serena_dir  then config.serena_dir  = opts.serena_dir  end
  if opts.module_info then config.module_info = opts.module_info end
  if opts.prompts     then config.prompts     = opts.prompts     end
  if opts.background_dim_on_explain ~= nil then config.background_dim_on_explain = opts.background_dim_on_explain end
  if opts.promptline then
    local ok, pl = pcall(require, "promptline")
    if ok then
      pl.setup(opts.promptline)
    end
  end
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
  vim.keymap.set("n", leader .. "k", M.peek, { desc = "Metroscope: peek explanation at cursor" })
end

return M
