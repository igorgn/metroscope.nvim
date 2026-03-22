-- metroscope.nvim
-- Visualize a codebase as an interactive metro map.

local M = {}

local config = {
  server = "http://127.0.0.1:7777",
}

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

-- ─── State ────────────────────────────────────────────────────────────────────

local state = {
  buf      = nil,
  win      = nil,
  data     = nil,   -- MapResponse
  line_idx    = 1,
  station_idx = 1,
}

-- ─── Layout constants ─────────────────────────────────────────────────────────

local LABEL_W   = 14   -- "[filename]    " column
local PAD       = 3    -- spaces between boxes
local BOX_MIN   = 6    -- minimum box inner width
local CROSS_SYM = "⬡"  -- marker for stations with cross-line connections
local DASH      = "─"

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function pad_right(s, n)
  local len = vim.fn.strdisplaywidth(s)
  return len >= n and s or (s .. string.rep(" ", n - len))
end

local function dashes(n)
  return string.rep(DASH, math.max(0, n))
end

local function word_wrap(s, w)
  local lines = {}
  while vim.fn.strdisplaywidth(s) > w do
    local cut = s:sub(1, w):match("^(.+)%s") or s:sub(1, w)
    table.insert(lines, cut)
    s = vim.trim(s:sub(#cut + 1))
  end
  if s ~= "" then table.insert(lines, s) end
  return lines
end

-- ─── Rendering ────────────────────────────────────────────────────────────────
--
-- Each station is a box:
--
--   ┌──────────────┐
--   │ station_name │
--   └──────────────┘
--
-- Focused station:
--   ╔══════════════╗
--   ║ station_name ║
--   ╚══════════════╝
--
-- With cross-line connections: ⬡ appended inside the box.
--
-- Lines are rendered as three rows (top border, name, bottom border) connected
-- by horizontal tracks on the middle row.

local function box(name, focused, cross)
  local label = cross and (name .. " " .. CROSS_SYM) or name
  local inner = math.max(vim.fn.strdisplaywidth(label) + 2, BOX_MIN)
  local pad_l = " "
  local pad_r = string.rep(" ", inner - vim.fn.strdisplaywidth(label) - 1)

  if focused then
    return {
      "╔" .. string.rep("═", inner) .. "╗",
      "║" .. pad_l .. label .. pad_r .. "║",
      "╚" .. string.rep("═", inner) .. "╝",
    }, inner + 2  -- total box width incl borders
  else
    return {
      "┌" .. string.rep("─", inner) .. "┐",
      "│" .. pad_l .. label .. pad_r .. "│",
      "└" .. string.rep("─", inner) .. "┘",
    }, inner + 2
  end
end

local function render_map(data)
  if not data or not data.lines then return {} end

  local out = {}

  for li, line in ipairs(data.lines) do
    local label = pad_right("[" .. line.name .. "]", LABEL_W)

    if #line.stations == 0 then
      table.insert(out, label .. " " .. dashes(8))
      table.insert(out, "")
      table.insert(out, "")
      table.insert(out, "")
    else
      -- Build per-station boxes
      local boxes = {}
      local widths = {}
      for si, st in ipairs(line.stations) do
        local focused = st.is_focused
            and state.line_idx == li
            and state.station_idx == si
        local b, w = box(st.name, focused, st.has_cross_line)
        boxes[si] = b
        widths[si] = w
      end

      -- Three-row render: top, mid (with track), bottom
      -- track connector: "──" between boxes, aligned to middle row

      -- top/bot rows: blank indent the same width as "label + ' ' + leading dashes"
      -- mid row:      label + leading dashes connect into the box middle
      local lead      = 2   -- leading dashes before first box
      local indent    = string.rep(" ", LABEL_W + 1 + lead)
      local top_row   = indent
      local mid_row   = label .. " " .. dashes(lead)
      local bot_row   = indent

      for si, b in ipairs(boxes) do
        top_row = top_row .. b[1]
        mid_row = mid_row .. b[2]
        bot_row = bot_row .. b[3]

        if si < #boxes then
          top_row = top_row .. string.rep(" ", PAD)
          mid_row = mid_row .. dashes(PAD)
          bot_row = bot_row .. string.rep(" ", PAD)
        end
      end

      table.insert(out, top_row)
      table.insert(out, mid_row)
      table.insert(out, bot_row)
      table.insert(out, "")   -- blank separator
    end
  end

  return out
end

-- Each line group = 4 rows (top, mid, bot, blank)
local ROWS_PER_LINE = 4

-- ─── Window ───────────────────────────────────────────────────────────────────

local function open_window()
  local width  = math.floor(vim.o.columns * 0.90)
  local height = math.floor(vim.o.lines   * 0.55)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].filetype   = "metroscope"
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " ⬡ Metroscope ",
    title_pos = "center",
    footer    = "  i:info  <CR>:jump  h/l:move  j/k:line  q:close  ",
    footer_pos = "center",
  })

  vim.wo[win].wrap       = false
  vim.wo[win].cursorline = false
  vim.wo[win].number     = false
  vim.wo[win].signcolumn = "no"

  return buf, win
end

-- ─── Highlights ───────────────────────────────────────────────────────────────

local ns = vim.api.nvim_create_namespace("metroscope")

local function setup_highlights()
  vim.api.nvim_set_hl(0, "MetroscopeFocusedBox",  { fg = "#FFD700", bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeCrossLine",   { fg = "#FF6B6B", bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeTrack",       { fg = "#555555" })
  vim.api.nvim_set_hl(0, "MetroscopeStatusKey",   { fg = "#888888" })
end

local function apply_highlights()
  if not state.buf or not state.data then return end
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

  for li, line in ipairs(state.data.lines) do
    local base = (li - 1) * ROWS_PER_LINE  -- 0-based row of top border

    -- Color the label on the middle row
    local mid_row = base + 1
    local hl_name = "MetroscopeLine" .. li
    vim.api.nvim_set_hl(0, hl_name, { fg = line.color, bold = true })
    vim.api.nvim_buf_add_highlight(state.buf, ns, hl_name, mid_row, 0, LABEL_W)

    -- Highlight focused box (all 3 rows) and cross-line markers
    for si, st in ipairs(line.stations) do
      local focused = st.is_focused and state.line_idx == li and state.station_idx == si

      if focused then
        -- Highlight the ╔═╗ / ║ ║ / ╚═╝ rows
        for row_off = 0, 2 do
          local row = base + row_off
          local text = vim.api.nvim_buf_get_lines(state.buf, row, row + 1, false)[1] or ""
          -- Find the focused box by scanning for ╔ or ║ or ╚
          local markers = { "╔", "║", "╚" }
          local start_byte = text:find(markers[row_off + 1], 1, true)
          if start_byte then
            local end_byte = text:find(row_off == 1 and "║" or (row_off == 0 and "╗" or "╝"), start_byte + 3, true)
            if end_byte then
              vim.api.nvim_buf_add_highlight(
                state.buf, ns, "MetroscopeFocusedBox",
                row, start_byte - 1, end_byte + 2
              )
            end
          end
        end
      end

      -- Highlight ⬡ cross-line symbol
      if st.has_cross_line then
        local mid = base + 1
        local text = vim.api.nvim_buf_get_lines(state.buf, mid, mid + 1, false)[1] or ""
        local pos = text:find(CROSS_SYM, 1, true)
        while pos do
          vim.api.nvim_buf_add_highlight(
            state.buf, ns, "MetroscopeCrossLine",
            mid, pos - 1, pos - 1 + #CROSS_SYM
          )
          pos = text:find(CROSS_SYM, pos + #CROSS_SYM, true)
        end
      end
    end
  end
end

-- ─── Redraw ───────────────────────────────────────────────────────────────────

local function redraw()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  local rendered = render_map(state.data)

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, rendered)
  vim.bo[state.buf].modifiable = false

  -- Scroll to focused line (middle row of the line group)
  local target = (state.line_idx - 1) * ROWS_PER_LINE + 2
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, { target, 0 })
  end

  apply_highlights()
end

-- ─── Navigation ───────────────────────────────────────────────────────────────

local function current_station()
  if not state.data then return nil end
  local line = state.data.lines[state.line_idx]
  if not line then return nil end
  return line.stations[state.station_idx]
end

local function move_right()
  local line = state.data and state.data.lines[state.line_idx]
  if line and state.station_idx < #line.stations then
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
  if state.data and state.line_idx < #state.data.lines then
    state.line_idx = state.line_idx + 1
    local line = state.data.lines[state.line_idx]
    state.station_idx = math.min(state.station_idx, math.max(1, #line.stations))
    redraw()
  end
end

local function move_up()
  if state.line_idx > 1 then
    state.line_idx = state.line_idx - 1
    local line = state.data.lines[state.line_idx]
    state.station_idx = math.min(state.station_idx, math.max(1, #line.stations))
    redraw()
  end
end

-- ─── Info popup ───────────────────────────────────────────────────────────────

local info_win = nil

local function close_info()
  if info_win and vim.api.nvim_win_is_valid(info_win) then
    vim.api.nvim_win_close(info_win, true)
  end
  info_win = nil
end

local function show_info()
  local st = current_station()
  if not st then return end
  close_info()

  local detail = fetch(config.server .. "/station/" .. st.id)
  local connections = fetch(config.server .. "/connections?file="
    .. vim.uri_encode(st.id:match("^(.+)::.+$") or ""))

  local W = 52
  local rows = {}

  local function push(s) table.insert(rows, s) end
  local function rule() push(string.rep("─", W - 2)) end
  local function blank() push("") end

  if detail and not detail.error then
    -- Header
    push(pad_right(" " .. detail.name, W - #detail.kind - 3) .. detail.kind .. " ")
    rule()
    blank()

    -- Summary (word-wrapped)
    local summary = (detail.summary ~= "" and detail.summary) or "(no summary)"
    for _, wline in ipairs(word_wrap(summary, W - 4)) do
      push("  " .. wline)
    end
    blank()

    -- Location
    push("  " .. detail.file .. "  :" .. detail.line_start .. "–" .. detail.line_end)
    blank()

    -- Calls (outgoing)
    if detail.calls and #detail.calls > 0 then
      push("  → Calls")
      for _, c in ipairs(detail.calls) do
        local name = pad_right("    " .. c.name, 22)
        local hint = c.summary ~= "" and c.summary:sub(1, W - 24) or ""
        push(name .. (hint ~= "" and "  " .. hint or ""))
      end
      blank()
    end

    -- Called by (incoming)
    if detail.called_by and #detail.called_by > 0 then
      push("  ← Called by")
      for _, c in ipairs(detail.called_by) do
        local name = pad_right("    " .. c.name, 22)
        local loc  = c.file ~= "" and c.file:match("[^/]+$") or ""
        push(name .. (loc ~= "" and "  " .. loc or ""))
      end
      blank()
    end

    -- Component connections (cross-file)
    if connections and (
      (#(connections.calls_into or {}) > 0) or
      (#(connections.called_from or {}) > 0)
    ) then
      push("  ⬡ Component connections")
      rule()
      for _, link in ipairs(connections.calls_into or {}) do
        push("  → " .. link.file_name)
        for _, c in ipairs(link.connections) do
          push("      " .. c.from_station .. " → " .. c.to_station)
        end
      end
      for _, link in ipairs(connections.called_from or {}) do
        push("  ← " .. link.file_name)
        for _, c in ipairs(link.connections) do
          push("      " .. c.from_station .. " → " .. c.to_station)
        end
      end
      blank()
    end
  else
    push(" " .. st.name)
    rule()
    blank()
    push("  " .. (st.summary ~= "" and st.summary or "(no summary)"))
    blank()
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false

  -- Position to the right of the map window, or below if no room
  local map_pos = vim.api.nvim_win_get_position(state.win)
  local map_w   = vim.api.nvim_win_get_width(state.win)
  local H = math.min(#rows, vim.o.lines - 4)

  local col = map_pos[2] + map_w + 1
  if col + W > vim.o.columns then
    col = math.max(0, vim.o.columns - W - 1)
  end
  local row = map_pos[1]

  info_win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    width     = W,
    height    = H,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = "  " .. (st.name or "") .. "  ",
    title_pos = "center",
    focusable = false,
  })

  -- Highlights in the info panel
  local info_ns = vim.api.nvim_create_namespace("metroscope_info")
  for i, line in ipairs(rows) do
    if line:match("^  →") then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "Function",   i - 1, 0, -1)
    elseif line:match("^  ←") then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "Identifier", i - 1, 0, -1)
    elseif line:match("^  ⬡") then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "MetroscopeCrossLine", i - 1, 0, -1)
    end
  end

  -- Auto-close on next navigation
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer   = state.buf,
    once     = true,
    callback = close_info,
  })
end

-- ─── Jump to code ─────────────────────────────────────────────────────────────

local function jump_to_code()
  local st = current_station()
  if not st then return end

  local file = st.id:match("^(.+)::.+$")
  if not file then return end
  local line_nr = st.line_start

  M.close()

  local target_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "metroscope" then
      target_win = w
      break
    end
  end
  if target_win then vim.api.nvim_set_current_win(target_win) end

  vim.cmd("edit " .. vim.fn.fnameescape(file))
  vim.api.nvim_win_set_cursor(0, { line_nr, 0 })
  vim.cmd("normal! zz")
end

-- ─── Keymaps ──────────────────────────────────────────────────────────────────

local function set_keymaps(buf)
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("h",     move_left)
  map("l",     move_right)
  map("j",     move_down)
  map("k",     move_up)
  map("i",     show_info)
  map("K",     show_info)
  map("<CR>",  jump_to_code)
  map("q",     M.close)
  map("<Esc>", M.close)
end

-- ─── Public API ───────────────────────────────────────────────────────────────

function M.close()
  close_info()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.buf = nil
  state.win = nil
end

function M.open()
  local file = vim.fn.expand("%:.")
  local line = vim.fn.line(".")
  local url  = config.server .. "/map?file=" .. vim.uri_encode(file) .. "&line=" .. line
  local data = fetch(url)

  if not data then
    vim.notify("Metroscope: server not reachable at " .. config.server, vim.log.levels.ERROR)
    return
  end

  state.data        = data
  state.line_idx    = 1
  state.station_idx = 1

  if data.focused_station then
    for li, ld in ipairs(data.lines) do
      for si, st in ipairs(ld.stations) do
        if st.is_focused then
          state.line_idx    = li
          state.station_idx = si
        end
      end
    end
  end

  setup_highlights()
  state.buf, state.win = open_window()
  set_keymaps(state.buf)
  redraw()
end

function M.index(project_root, api_key)
  project_root = project_root or vim.fn.getcwd()
  api_key      = api_key or vim.env.ANTHROPIC_API_KEY or ""
  local cmd = string.format(
    "metroscope-indexer index %s --api-key %s",
    vim.fn.shellescape(project_root),
    vim.fn.shellescape(api_key)
  )
  vim.cmd("botright 15split | terminal " .. cmd)
end

function M.setup(opts)
  opts = opts or {}
  if opts.server then config.server = opts.server end
  local leader = opts.leader or "<leader>m"
  vim.keymap.set("n", leader .. "s", M.open, { desc = "Metroscope: open map" })
  vim.keymap.set("n", leader .. "i", function()
    M.index(vim.fn.getcwd(), vim.env.ANTHROPIC_API_KEY)
  end, { desc = "Metroscope: re-index" })
end

return M
