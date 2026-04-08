-- Station list zoom level (telescope-style list + preview)

local st = require("metroscope.state")
local util = require("metroscope.util")
local info_mod = require("metroscope.info")

local state = st.state
local LABEL_W = st.LABEL_W

local M = {}

function M.close_station_list()
  pcall(vim.api.nvim_del_augroup_by_name, "MetroscopeSLGuard")
  if state.sl_prev_win and vim.api.nvim_win_is_valid(state.sl_prev_win) then
    vim.api.nvim_win_close(state.sl_prev_win, true)
  end
  if state.sl_list_win and vim.api.nvim_win_is_valid(state.sl_list_win) then
    vim.api.nvim_win_close(state.sl_list_win, true)
  end
  state.sl_prev_win = nil
  state.sl_prev_buf = nil
  state.sl_list_win = nil
  state.sl_list_buf = nil
  state.sl_stations = nil
  state.sl_prev_keymaps = nil
end

function M.sl_update_preview()
  local s = state.sl_stations and state.sl_stations[state.sl_idx]
  if not s or not state.sl_prev_win then
    return
  end
  if not vim.api.nvim_win_is_valid(state.sl_prev_win) then
    return
  end

  local abs_file = (state.project_root or "") .. "/" .. (s.id:match("^(.+)::.+$") or "")
  local lines = {}
  local ok = pcall(function()
    local f = io.open(abs_file, "r")
    if not f then
      return
    end
    for l in f:lines() do
      table.insert(lines, l)
    end
    f:close()
  end)
  if not ok or #lines == 0 then
    lines = { "(preview unavailable)" }
  end

  local prev_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[prev_buf].buftype = "nofile"
  vim.bo[prev_buf].bufhidden = "wipe"
  vim.bo[prev_buf].filetype = abs_file:match("%.(%w+)$") == "rs" and "rust" or ""
  vim.api.nvim_buf_set_lines(prev_buf, 0, -1, false, lines)
  vim.bo[prev_buf].modifiable = false

  -- Dim lines outside the function body
  local fn_start = math.max(1, s.line_start or 1)
  local fn_end = math.max(fn_start, s.line_end or fn_start)
  local dim_ns = vim.api.nvim_create_namespace("metroscope_prev_dim")
  vim.api.nvim_set_hl(0, "MetroscopePreviewDim", { fg = "#555555", bg = "NONE" })
  for i = 1, #lines do
    if i < fn_start or i > fn_end then
      vim.api.nvim_buf_add_highlight(prev_buf, dim_ns, "MetroscopePreviewDim", i - 1, 0, -1)
    end
  end

  local old_buf = state.sl_prev_buf
  vim.api.nvim_win_set_buf(state.sl_prev_win, prev_buf)
  state.sl_prev_buf = prev_buf
  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    vim.api.nvim_buf_delete(old_buf, { force = true })
  end

  -- Re-apply preview keymaps on the new buffer (keymaps are lost when buffer is replaced)
  if state.sl_prev_keymaps then
    for key, fn in pairs(state.sl_prev_keymaps) do
      vim.keymap.set("n", key, fn, { buffer = prev_buf, nowait = true, silent = true })
    end
  end

  -- Scroll so function start is at the top of the window
  local max = vim.api.nvim_buf_line_count(prev_buf)
  vim.api.nvim_win_set_cursor(state.sl_prev_win, { math.min(fn_start, max), 0 })
  vim.api.nvim_win_call(state.sl_prev_win, function()
    vim.cmd("normal! zt")
  end)
end

function M.sl_update_list()
  if not state.sl_list_buf or not state.sl_stations then
    return
  end
  local rows = {}
  for i, s in ipairs(state.sl_stations) do
    local prefix = (i == state.sl_idx) and " ▶ " or "   "
    local loc = ":" .. (s.line_start or "?")
    rows[i] = prefix .. util.pad_right(s.name, 22) .. loc
  end
  vim.bo[state.sl_list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.sl_list_buf, 0, -1, false, rows)
  vim.bo[state.sl_list_buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("metroscope_sl")
  vim.api.nvim_buf_clear_namespace(state.sl_list_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(state.sl_list_buf, ns, "MetroscopeFocusedName", state.sl_idx - 1, 0, -1)

  if vim.api.nvim_win_is_valid(state.sl_list_win) then
    vim.api.nvim_win_set_cursor(state.sl_list_win, { state.sl_idx, 0 })
  end
end

function M.zoom_to_stations(line, close_all_fn, explain_off_fn)
  info_mod.close_info() -- dismiss any open info popup before entering station list

  local stations = {}
  if state.data and state.data.lines then
    for _, l in ipairs(state.data.lines) do
      if l.id == line.id then
        stations = l.stations
        break
      end
    end
  end
  if #stations == 0 then
    return
  end

  state.zoom = "stations"
  state.sl_stations = stations
  state.sl_idx = 1

  local total_w = math.floor(vim.o.columns * 0.90)
  local height = math.floor(vim.o.lines * 0.75)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - total_w) / 2)
  local list_w = 32
  local prev_w = total_w - list_w - 1

  local lb = vim.api.nvim_create_buf(false, true)
  vim.bo[lb].buftype = "nofile"
  vim.bo[lb].bufhidden = "wipe"
  vim.bo[lb].modifiable = false
  local lw = vim.api.nvim_open_win(lb, true, {
    relative = "editor",
    width = list_w,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = "  " .. line.name .. "  ",
    title_pos = "center",
    footer = "  j/k:move  e:explain  <Tab>:preview  C-f/b:scroll  <CR>:jump  b:back  q:close  ",
    footer_pos = "center",
    zindex = 60,
  })
  vim.wo[lw].wrap = false
  vim.wo[lw].cursorline = false
  vim.wo[lw].number = false
  vim.wo[lw].signcolumn = "no"

  local pb = vim.api.nvim_create_buf(false, true)
  vim.bo[pb].buftype = "nofile"
  vim.bo[pb].bufhidden = "wipe"
  local pw = vim.api.nvim_open_win(pb, false, {
    relative = "editor",
    width = prev_w,
    height = height,
    row = row,
    col = col + list_w + 1,
    style = "minimal",
    border = "rounded",
    title = "  preview  ",
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[pw].wrap = false
  vim.wo[pw].cursorline = true
  vim.wo[pw].number = true
  vim.wo[pw].signcolumn = "no"

  state.sl_list_buf = lb
  state.sl_list_win = lw
  state.sl_prev_buf = pb
  state.sl_prev_win = pw

  M.sl_update_list()
  M.sl_update_preview()
  -- sl_update_preview replaces+deletes pb, so state.sl_prev_buf is now a different buffer.
  -- pmap must use state.sl_prev_buf, not the stale pb local.

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = lb, nowait = true, silent = true })
  end
  local function pmap(key, fn)
    vim.keymap.set("n", key, fn, { buffer = state.sl_prev_buf, nowait = true, silent = true })
  end

  -- Refresh explain float for the current station if it's already open
  local function refresh_explain()
    if not (info_mod.explain_win and vim.api.nvim_win_is_valid(info_mod.explain_win)) then
      return
    end
    local s = state.sl_stations and state.sl_stations[state.sl_idx]
    if not s then
      return
    end
    -- Close and reopen without toggling (force reopen by clearing the win first)
    vim.api.nvim_win_close(info_mod.explain_win, true)
    info_mod.explain_win = nil
    info_mod.open_explain_float(s.id, s.name, state.sl_prev_win)
  end

  map("j", function()
    if state.sl_idx < #state.sl_stations then
      state.sl_idx = state.sl_idx + 1
      M.sl_update_list()
      M.sl_update_preview()
      refresh_explain()
    end
  end)
  map("k", function()
    if state.sl_idx > 1 then
      state.sl_idx = state.sl_idx - 1
      M.sl_update_list()
      M.sl_update_preview()
      refresh_explain()
    end
  end)

  local function sl_jump()
    local s = state.sl_stations[state.sl_idx]
    if not s then
      return
    end
    local file = s.id:match("^(.+)::.+$")
    if not file then
      return
    end
    local abs_file = (state.project_root or "") .. "/" .. file
    M.close_station_list()
    if close_all_fn then
      close_all_fn()
    end
    util.jump_to_file(abs_file, s.line_start)
  end

  local function sl_back()
    pcall(vim.api.nvim_del_augroup_by_name, "MetroscopeSLGuard")
    state.zoom = "functions"
    if explain_off_fn then
      explain_off_fn()
    else
      info_mod.close_explain()
    end
    M.close_station_list()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_set_current_win(state.win)
    end
  end

  local function scroll_preview(dir)
    if not state.sl_prev_win or not vim.api.nvim_win_is_valid(state.sl_prev_win) then
      return
    end
    vim.api.nvim_win_call(state.sl_prev_win, function()
      vim.cmd("normal! " .. dir)
    end)
  end

  local function sl_explain()
    local s = state.sl_stations and state.sl_stations[state.sl_idx]
    if not s then
      return
    end
    info_mod.open_explain_float(s.id, s.name, state.sl_prev_win)
  end

  local function focus_list()
    if vim.api.nvim_win_is_valid(lw) then
      vim.api.nvim_set_current_win(lw)
    end
  end

  map("<CR>", sl_jump)
  map("e", sl_explain)
  map("b", sl_back)
  map("<C-f>", function()
    scroll_preview("\6")
  end)
  map("<C-b>", function()
    scroll_preview("\2")
  end)
  local function sl_close()
    if explain_off_fn then
      explain_off_fn()
    else
      info_mod.close_explain()
    end
    M.close_station_list()
    if close_all_fn then
      close_all_fn()
    end
  end

  map("q", sl_close)
  map("<Esc>", sl_close)

  -- Store keymaps so sl_update_preview re-applies them on every new buffer swap
  state.sl_prev_keymaps = {
    ["<Tab>"] = focus_list,
    ["e"] = sl_explain,
    ["b"] = sl_back,
    ["<CR>"] = sl_jump,
    ["q"] = sl_close,
    ["<Esc>"] = sl_close,
  }
  for key, fn in pairs(state.sl_prev_keymaps) do
    pmap(key, fn)
  end

  -- Guard: if focus escapes to a window outside the station list, close everything
  local sl_wins = { lw, pw }
  local function is_sl_win(w)
    for _, sw in ipairs(sl_wins) do
      if sw == w then
        return true
      end
    end
    -- also allow the explain float and map window
    if state.win and w == state.win then
      return true
    end
    if info_mod.explain_win and w == info_mod.explain_win then
      return true
    end
    return false
  end
  local guard_au = vim.api.nvim_create_augroup("MetroscopeSLGuard", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = guard_au,
    callback = function()
      local cur = vim.api.nvim_get_current_win()
      if state.zoom ~= "stations" then
        vim.api.nvim_del_augroup_by_id(guard_au)
        return
      end
      if not is_sl_win(cur) then
        vim.api.nvim_del_augroup_by_id(guard_au)
        M.close_station_list()
        if close_all_fn then
          close_all_fn()
        end
      end
    end,
  })
end

return M
