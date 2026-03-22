-- metroscope.nvim
-- Visualize a codebase as an interactive metro map.

local M = {}

local config = {
  server = "http://127.0.0.1:7777",
}

-- ─── HTTP helpers ─────────────────────────────────────────────────────────────

local function fetch(url)
  local handle = io.popen('curl -s --max-time 2 "' .. url .. '"')
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  if not result or result == "" then return nil end
  return vim.json.decode(result)
end

-- ─── Map state ────────────────────────────────────────────────────────────────

local state = {
  buf = nil,
  win = nil,
  data = nil,        -- MapResponse from server
  -- cursor position within the map
  line_idx = 1,      -- which Line we're on (1-based)
  station_idx = 1,   -- which Station on that line (1-based)
}

-- ─── Rendering ────────────────────────────────────────────────────────────────

local STATION     = "●"
local STATION_YOU = "◉"
local TRACK       = "──"
local TRACK_START = "──"

local function pad_right(s, n)
  local len = vim.fn.strdisplaywidth(s)
  if len >= n then return s end
  return s .. string.rep(" ", n - len)
end

local function render_map(data)
  if not data or not data.lines then return {} end

  local lines_out = {}
  local cursor_line = nil  -- line number in buffer for cursor

  for li, line in ipairs(data.lines) do
    local label = pad_right("[" .. line.name .. "]", 12)

    -- Track line
    local track = label .. " " .. TRACK_START
    local names = {}

    for si, st in ipairs(line.stations) do
      local sym = (st.is_focused and state.line_idx == li and state.station_idx == si)
          and STATION_YOU or STATION
      track = track .. sym .. TRACK .. TRACK
      table.insert(names, st.name)
    end

    table.insert(lines_out, track)

    -- Station names line (indented under the track)
    local indent = string.rep(" ", vim.fn.strdisplaywidth(label) + 2 + #TRACK_START)
    local name_line = indent
    for _, nm in ipairs(names) do
      name_line = name_line .. pad_right(nm, #STATION + #TRACK + #TRACK + 2)
    end
    table.insert(lines_out, name_line)

    -- Blank separator between lines
    table.insert(lines_out, "")
  end

  return lines_out
end

-- ─── Window management ────────────────────────────────────────────────────────

local function open_window()
  local width  = math.floor(vim.o.columns * 0.85)
  local height = math.floor(vim.o.lines * 0.5)
  local row    = math.floor((vim.o.lines - height) / 2)
  local col    = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].filetype   = "metroscope"
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width    = width,
    height   = height,
    row      = row,
    col      = col,
    style    = "minimal",
    border   = "rounded",
    title    = " Metroscope ",
    title_pos = "center",
  })

  vim.wo[win].wrap        = false
  vim.wo[win].cursorline  = false
  vim.wo[win].number      = false
  vim.wo[win].signcolumn  = "no"

  return buf, win
end

local function redraw()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  local rendered = render_map(state.data)

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, rendered)
  vim.bo[state.buf].modifiable = false

  -- Position cursor on the focused track line (every line group = 3 lines)
  local target_buf_line = (state.line_idx - 1) * 3 + 1
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, { target_buf_line, 0 })
  end

  -- Apply highlights
  M.apply_highlights()
end

-- ─── Highlights ───────────────────────────────────────────────────────────────

function M.apply_highlights()
  if not state.buf or not state.data then return end
  vim.api.nvim_buf_clear_namespace(state.buf, -1, 0, -1)

  local ns = vim.api.nvim_create_namespace("metroscope")

  for li, line in ipairs(state.data.lines) do
    local buf_line = (li - 1) * 3  -- 0-based
    -- Color the bracket label
    local color_hl = "MetroscopeLine" .. li
    vim.api.nvim_set_hl(0, color_hl, { fg = line.color, bold = true })
    vim.api.nvim_buf_add_highlight(state.buf, ns, color_hl, buf_line, 0, 12)

    -- Highlight focused station symbol
    if state.line_idx == li then
      for si, st in ipairs(line.stations) do
        if st.is_focused then
          -- approximate column: label(12) + space(1) + track_start(4) + per station offset
          local col = 12 + 1 + #TRACK_START + (si - 1) * (#STATION + #TRACK + #TRACK)
          vim.api.nvim_buf_add_highlight(state.buf, ns, "MetroscopeFocused", buf_line, col, col + #STATION_YOU)
        end
      end
    end
  end
end

vim.api.nvim_set_hl(0, "MetroscopeFocused", { fg = "#FFD700", bold = true })

-- ─── Navigation ───────────────────────────────────────────────────────────────

local function current_station()
  if not state.data then return nil end
  local line = state.data.lines[state.line_idx]
  if not line then return nil end
  return line.stations[state.station_idx]
end

local function move_right()
  if not state.data then return end
  local line = state.data.lines[state.line_idx]
  if not line then return end
  if state.station_idx < #line.stations then
    state.station_idx = state.station_idx + 1
    redraw()
  end
end

local function move_left()
  if state.station_idx > 1 then
    state.station_idx = state.station_idx - 1
    redraw()
  end
end

local function move_down()
  if not state.data then return end
  if state.line_idx < #state.data.lines then
    state.line_idx = state.line_idx + 1
    -- Clamp station index to the new line's length
    local line = state.data.lines[state.line_idx]
    state.station_idx = math.min(state.station_idx, #line.stations)
    redraw()
  end
end

local function move_up()
  if state.line_idx > 1 then
    state.line_idx = state.line_idx - 1
    local line = state.data.lines[state.line_idx]
    state.station_idx = math.min(state.station_idx, #line.stations)
    redraw()
  end
end

local function show_summary()
  local st = current_station()
  if not st then return end

  local lines = {
    "  " .. st.name .. "  ",
    string.rep("─", 50),
    "",
    "  " .. (st.summary ~= "" and st.summary or "(no summary)"),
    "",
  }

  -- Show in a small floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = 54
  local height = #lines
  local row = vim.api.nvim_win_get_position(state.win)[1] - height - 2
  if row < 0 then row = 2 end
  local col = math.floor((vim.o.columns - width) / 2)

  local popup = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    focusable = false,
  })

  -- Auto-close after 4s or on any keypress in the map
  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(popup) then
      vim.api.nvim_win_close(popup, true)
    end
  end, 4000)
end

local function jump_to_code()
  local st = current_station()
  if not st then return end

  -- Parse station id: "path/to/file.rs::fn_name"
  local file, _ = st.id:match("^(.+)::.+$")
  if not file then return end

  local line_nr = st.line_start

  -- Close the map first
  M.close()

  -- Find a window that shows non-metroscope buffers, or open a split
  local target_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(w)
    if vim.bo[buf].filetype ~= "metroscope" then
      target_win = w
      break
    end
  end

  if target_win then
    vim.api.nvim_set_current_win(target_win)
  end

  -- Open the file
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  vim.api.nvim_win_set_cursor(0, { line_nr, 0 })
  vim.cmd("normal! zz")
end

local function set_keymaps(buf)
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("l",     move_right)
  map("h",     move_left)
  map("j",     move_down)
  map("k",     move_up)
  map("K",     show_summary)
  map("<CR>",  jump_to_code)
  map("q",     M.close)
  map("<Esc>", M.close)
end

-- ─── Public API ───────────────────────────────────────────────────────────────

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.buf = nil
  state.win = nil
end

--- Open the metro map centered on the current cursor position.
function M.open()
  local file = vim.fn.expand("%:.")  -- relative path
  local line = vim.fn.line(".")

  local url = config.server .. "/map?file=" .. vim.uri_encode(file) .. "&line=" .. line
  local data = fetch(url)

  if not data then
    vim.notify("Metroscope: server not reachable at " .. config.server, vim.log.levels.ERROR)
    return
  end

  state.data = data
  state.line_idx = 1
  state.station_idx = 1

  -- Find which line/station is focused
  if data.focused_station then
    for li, line_data in ipairs(data.lines) do
      for si, st in ipairs(line_data.stations) do
        if st.is_focused then
          state.line_idx    = li
          state.station_idx = si
          break
        end
      end
    end
  end

  state.buf, state.win = open_window()
  set_keymaps(state.buf)
  redraw()
end

--- Trigger re-indexing of a project.
function M.index(project_root, api_key)
  project_root = project_root or vim.fn.getcwd()
  api_key      = api_key or vim.env.ANTHROPIC_API_KEY or ""

  local cmd = string.format(
    "metroscope-indexer index %s --api-key %s",
    vim.fn.shellescape(project_root),
    vim.fn.shellescape(api_key)
  )

  -- Run in a terminal buffer so the user can watch progress
  vim.cmd("botright 15split | terminal " .. cmd)
end

--- Setup keymaps.
function M.setup(opts)
  opts = opts or {}
  if opts.server then config.server = opts.server end

  local leader = opts.leader or "<leader>m"
  vim.keymap.set("n", leader .. "s", M.open,  { desc = "Metroscope: open map" })
  vim.keymap.set("n", leader .. "i", function()
    M.index(vim.fn.getcwd(), vim.env.ANTHROPIC_API_KEY)
  end, { desc = "Metroscope: re-index project" })
end

return M
