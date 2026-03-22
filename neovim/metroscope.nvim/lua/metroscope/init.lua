-- metroscope.nvim
-- Visualize a codebase as an interactive metro map.

local M = {}

local config = {
  server          = "http://127.0.0.1:7777",
  serena_dir      = nil,   -- optional: path to serena repo for LSP-accurate call graph
  module_info     = "detailed",  -- "detailed" | "compact" — how much to show in module popup
  -- LLM prompt overrides (passed to indexer at index time)
  prompts = {
    functions = nil,  -- replaces the function summary instruction
    file      = nil,  -- replaces the file/module summary instruction
    system    = nil,  -- replaces the system summary instruction
  },
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
  buf          = nil,
  win          = nil,
  data         = nil,   -- MapResponse (function view) or ModuleMap (module view)
  zoom         = "functions",  -- "functions" | "modules"
  crate_filter = nil,   -- when set, function view is scoped to this crate id
  line_idx     = 1,
  station_idx  = 1,
  info_pinned  = false, -- when true, info popup stays open and updates on navigation
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
        -- Use state cursor position as the source of truth for focused,
        -- not the server-provided is_focused (which only reflects initial cursor pos)
        local focused = (state.line_idx == li and state.station_idx == si)
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

-- ─── Module map rendering ─────────────────────────────────────────────────────
--
-- Each module is a box showing name + station count.
-- Connection indicators (│) are drawn between rows where modules connect.
--
--   [indexer/main]  ── main ⬡ ──────────────────────────────────
--                          │
--   [server/main]   ── map ── main ⬡
--

local function render_module_map(data)
  if not data or not data.modules then return {} end

  local modules = data.modules
  local out = {}

  -- Build a lookup: module id → display index (1-based)
  local mod_idx = {}
  for i, m in ipairs(modules) do mod_idx[m.id] = i end

  for mi, m in ipairs(modules) do
    local focused = (state.zoom == "modules" and state.line_idx == mi)
    local label   = pad_right("[" .. m.name .. "]", LABEL_W)
    local count   = "(" .. m.station_count .. ")"
    local b, _    = box(m.name .. "  " .. count, focused, #m.calls_into > 0)

    local lead   = 2
    local indent = string.rep(" ", LABEL_W + 1 + lead)
    local top_row = indent .. b[1]
    local mid_row = label .. " " .. dashes(lead) .. b[2]
    local bot_row = indent .. b[3]

    -- Connection indicators: for each module this one calls into,
    -- if the target is rendered below, show a │ connector row
    local conn_rows = {}
    for _, target_id in ipairs(m.calls_into) do
      local ti = mod_idx[target_id]
      if ti and ti > mi then
        -- draw a vertical connector at the box column position
        table.insert(conn_rows, indent .. "│  calls → " ..
          (modules[ti] and modules[ti].name or target_id))
      end
    end

    table.insert(out, top_row)
    table.insert(out, mid_row)
    table.insert(out, bot_row)
    if #conn_rows > 0 then
      for _, cr in ipairs(conn_rows) do table.insert(out, cr) end
    end
    table.insert(out, "")
  end

  return out
end

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
    footer    = "  i:info  <CR>:jump  h/l:move  j/k:line  b:modules  q:close  ",
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
  vim.api.nvim_set_hl(0, "MetroscopeFocusedName",  { bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeArrow",        { bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeCrossLine",    { fg = "#FF6B6B", bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeTrack",        { fg = "#555555" })
  vim.api.nvim_set_hl(0, "MetroscopeStatusKey",    { fg = "#888888" })
end

local function apply_highlights()
  if not state.buf or not state.data then return end
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

  if state.zoom == "modules" then
    -- Module view: highlight focused module box and connection indicators
    for mi, m in ipairs(state.data.modules or {}) do
      local base = (mi - 1) * ROWS_PER_LINE
      local mid_row = base + 1
      local hl_name = "MetroscopeLine" .. mi
      vim.api.nvim_set_hl(0, hl_name, { fg = m.color, bold = true })
      vim.api.nvim_buf_add_highlight(state.buf, ns, hl_name, mid_row, 0, LABEL_W)

      if state.line_idx == mi then
        local mid_text = vim.api.nvim_buf_get_lines(state.buf, mid_row, mid_row + 1, false)[1] or ""
        local open_b = mid_text:find("║", 1, true)
        if open_b then
          local close_b = mid_text:find("║", open_b + #"║", true)
          if close_b then
            vim.api.nvim_buf_add_highlight(
              state.buf, ns, "MetroscopeFocusedName",
              mid_row, open_b - 1 + #"║", close_b - 1
            )
          end
        end
      end

      -- Highlight ⬡ and │ connection indicators
      local mid_text = vim.api.nvim_buf_get_lines(state.buf, mid_row, mid_row + 1, false)[1] or ""
      local pos = 1
      while true do
        local s = mid_text:find(CROSS_SYM, pos, true)
        if not s then break end
        vim.api.nvim_buf_add_highlight(state.buf, ns, "MetroscopeCrossLine", mid_row, s - 1, s - 1 + #CROSS_SYM)
        pos = s + #CROSS_SYM
      end
    end
    return
  end

  for li, line in ipairs(state.data.lines or {}) do
    local base = (li - 1) * ROWS_PER_LINE  -- 0-based row of top border

    -- Color the label on the middle row
    local mid_row = base + 1
    local hl_name = "MetroscopeLine" .. li
    vim.api.nvim_set_hl(0, hl_name, { fg = line.color, bold = true })
    vim.api.nvim_buf_add_highlight(state.buf, ns, hl_name, mid_row, 0, LABEL_W)

    -- Highlight focused box and cross-line markers
    for si, st in ipairs(line.stations) do
      local focused = (state.line_idx == li and state.station_idx == si)

      if focused then
        -- Only bold the station name on the middle row (between ║ ... ║)
        local mid_text = vim.api.nvim_buf_get_lines(state.buf, base + 1, base + 2, false)[1] or ""
        local open_b = mid_text:find("║", 1, true)
        if open_b then
          local close_b = mid_text:find("║", open_b + #"║", true)
          if close_b then
            -- name sits between the two ║ characters
            local name_start = open_b - 1 + #"║"
            local name_end   = close_b - 1
            vim.api.nvim_buf_add_highlight(
              state.buf, ns, "MetroscopeFocusedName",
              base + 1, name_start, name_end
            )
          end
        end
      end

      if st.has_cross_line then
        local mid_text = vim.api.nvim_buf_get_lines(state.buf, base + 1, base + 2, false)[1] or ""
        local pos = 1
        while true do
          local s = mid_text:find(CROSS_SYM, pos, true)
          if not s then break end
          vim.api.nvim_buf_add_highlight(
            state.buf, ns, "MetroscopeCrossLine",
            base + 1, s - 1, s - 1 + #CROSS_SYM
          )
          pos = s + #CROSS_SYM
        end
      end
    end
  end
end

-- ─── Redraw ───────────────────────────────────────────────────────────────────

local function redraw()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  setup_highlights()
  local rendered = state.zoom == "modules"
    and render_module_map(state.data)
    or  render_map(state.data)

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, rendered)
  vim.bo[state.buf].modifiable = false

  -- Scroll to focused line (middle row of the line group)
  local target = (state.line_idx - 1) * ROWS_PER_LINE + 2
  local max_lines = vim.api.nvim_buf_line_count(state.buf)
  target = math.min(target, math.max(1, max_lines))
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, { target, 0 })
  end

  apply_highlights()

  -- If info is pinned, refresh it for the new position
  if state.info_pinned then
    vim.schedule(show_info)
  end
end

-- ─── Navigation ───────────────────────────────────────────────────────────────

local function current_station()
  if not state.data then return nil end
  if state.zoom == "modules" then return nil end
  local line = state.data.lines and state.data.lines[state.line_idx]
  if not line then return nil end
  return line.stations[state.station_idx]
end

local function current_module()
  if not state.data then return nil end
  if state.zoom ~= "modules" then return nil end
  return state.data.modules and state.data.modules[state.line_idx]
end

local function move_right()
  local line = state.data and state.data.lines and state.data.lines[state.line_idx]
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
  if not state.data then return end
  local items = state.zoom == "modules" and state.data.modules or state.data.lines
  if not items then return end
  if state.line_idx < #items then
    state.line_idx = state.line_idx + 1
    if state.zoom ~= "modules" then
      local line = items[state.line_idx]
      state.station_idx = math.min(state.station_idx, math.max(1, #line.stations))
    end
    redraw()
  end
end

local function move_up()
  if not state.data then return end
  if state.line_idx > 1 then
    state.line_idx = state.line_idx - 1
    if state.zoom ~= "modules" then
      local items = state.data.lines
      if items then
        local line = items[state.line_idx]
        state.station_idx = math.min(state.station_idx, math.max(1, #line.stations))
      end
    end
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

local function build_info_rows(title, summary, file_id, detail, connections)
  local W = 52
  local rows = {}
  local jump_targets = {}  -- row index (1-based) -> { file, line }
  local function push(s, target)
    table.insert(rows, s)
    if target then jump_targets[#rows] = target end
  end
  local function rule() push(string.rep("─", W - 2)) end
  local function blank() push("") end

  if detail and not detail.error then
    local kind = detail.kind or ""
    push(pad_right(" " .. title, W - #kind - 3) .. kind .. " ")
    rule()
    blank()

    local summary_text = (detail.summary ~= "" and detail.summary) or "(no summary)"
    for _, wl in ipairs(word_wrap(summary_text, W - 4)) do push("  " .. wl) end
    blank()

    if detail.file then
      push("  " .. detail.file .. "  :" .. (detail.line_start or "") .. "–" .. (detail.line_end or ""),
        { file = detail.file, line = detail.line_start })
      blank()
    end

    if detail.calls and #detail.calls > 0 then
      push("  → Calls")
      for _, c in ipairs(detail.calls) do
        local name = pad_right("  ▸ " .. c.name, 24)
        local hint = c.summary ~= "" and c.summary:sub(1, W - 26) or ""
        push(name .. (hint ~= "" and "  " .. hint or ""),
          { file = c.file, line = c.line_start })
      end
      blank()
    end

    if detail.called_by and #detail.called_by > 0 then
      push("  ← Called by")
      for _, c in ipairs(detail.called_by) do
        local name = pad_right("  ▸ " .. c.name, 24)
        local loc  = c.file ~= "" and (c.file:match("[^/]+$") or "") or ""
        push(name .. (loc ~= "" and "  " .. loc or ""),
          { file = c.file, line = c.line_start })
      end
      blank()
    end
  else
    push(" " .. title)
    rule()
    blank()
    local s = summary or "(no summary)"
    for _, wl in ipairs(word_wrap(s, W - 4)) do push("  " .. wl) end
    blank()
  end

  -- Component connections (cross-file) — shown for both station and component view
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

  return rows, W, jump_targets
end

local function open_info_popup(title, rows, W, jump_targets)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false

  local map_pos = vim.api.nvim_win_get_position(state.win)
  local map_w   = vim.api.nvim_win_get_width(state.win)
  local H = math.min(#rows, vim.o.lines - 4)
  local col = map_pos[2] + map_w + 1
  if col + W > vim.o.columns then col = math.max(0, vim.o.columns - W - 1) end

  info_win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    width     = W,
    height    = H,
    row       = map_pos[1],
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = "  " .. title .. "  ",
    title_pos = "center",
    focusable = true,
    zindex    = 100,
  })

  local info_ns  = vim.api.nvim_create_namespace("metroscope_info")
  local arrow_ns = vim.api.nvim_create_namespace("metroscope_info_arrow")
  for i, line in ipairs(rows) do
    if line:match("^  →") then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "Function",   i - 1, 0, -1)
    elseif line:match("^  ←") then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "Identifier", i - 1, 0, -1)
    elseif line:match("^  ⬡") then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "MetroscopeCrossLine", i - 1, 0, -1)
    end
  end

  -- Arrow cursor: tracks which line the user is on in the popup
  local arrow_row = 0  -- 0-indexed

  local function draw_arrow(row)
    vim.api.nvim_buf_clear_namespace(buf, arrow_ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, arrow_ns, row, 0, {
      virt_text       = { { "▶", "MetroscopeArrow" } },
      virt_text_pos   = "overlay",
      hl_mode         = "combine",
    })
  end

  draw_arrow(arrow_row)

  -- Keymaps inside info popup: j/k scroll, q/<Esc>/<Tab> return focus to map
  local function focus_map()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_set_current_win(state.win)
    end
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q",     close_info, opts)
  vim.keymap.set("n", "<Esc>", close_info, opts)
  vim.keymap.set("n", "<Tab>", focus_map,  opts)
  vim.keymap.set("n", "j", function()
    local max = vim.api.nvim_buf_line_count(buf) - 1
    if arrow_row < max then
      arrow_row = arrow_row + 1
      draw_arrow(arrow_row)
      vim.api.nvim_win_set_cursor(info_win, { arrow_row + 1, 0 })
    end
  end, opts)
  vim.keymap.set("n", "k", function()
    if arrow_row > 0 then
      arrow_row = arrow_row - 1
      draw_arrow(arrow_row)
      vim.api.nvim_win_set_cursor(info_win, { arrow_row + 1, 0 })
    end
  end, opts)

  -- Pressing i while in info popup: close and return to map
  vim.keymap.set("n", "i", function()
    close_info()
    focus_map()
  end, opts)

  -- Enter: jump to the file/line of the row under the arrow
  vim.keymap.set("n", "<CR>", function()
    local target = jump_targets and jump_targets[arrow_row + 1]
    if not target or not target.file or target.file == "" then return end
    close_info()
    M.close()
    local target_win = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "metroscope" then
        target_win = w; break
      end
    end
    if target_win then vim.api.nvim_set_current_win(target_win) end
    local lnum = math.max(1, target.line or 1)
    vim.cmd("edit " .. vim.fn.fnameescape(target.file))
    vim.schedule(function()
      local max = vim.api.nvim_buf_line_count(0)
      vim.api.nvim_win_set_cursor(0, { math.min(lnum, max), 0 })
      vim.cmd("normal! zz")
    end)
  end, opts)

  -- Only auto-close on cursor move when not pinned
  if not state.info_pinned then
    vim.schedule(function()
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
      vim.api.nvim_create_autocmd("CursorMoved", {
        buffer   = state.buf,
        once     = true,
        callback = close_info,
      })
    end)
  end
end

local function build_module_info_rows(m)
  local W = 56
  local rows = {}
  local jump_targets = {}
  local function push(s, target)
    table.insert(rows, s)
    if target then jump_targets[#rows] = target end
  end
  local function rule() push(string.rep("─", W - 2)) end
  local function blank() push("") end

  push(" " .. m.name .. "  (" .. m.station_count .. " functions)")
  rule()
  blank()

  local summary = (m.summary ~= "" and m.summary) or "(no summary)"
  for _, wl in ipairs(word_wrap(summary, W - 4)) do push("  " .. wl) end
  blank()

  if config.module_info == "detailed" then
    if #m.calls_into > 0 then
      push("  → Calls into")
      for _, cid in ipairs(m.calls_into) do
        push("  ▸ " .. cid)
      end
      blank()
    end
    if #m.called_from > 0 then
      push("  ← Called from")
      for _, cid in ipairs(m.called_from) do
        push("  ▸ " .. cid)
      end
      blank()
    end
  end

  return rows, W, jump_targets
end

local function show_info()
  close_info()

  -- Module view: show crate-level info
  local m = current_module()
  if m then
    local rows, W, jt = build_module_info_rows(m)
    open_info_popup(m.name, rows, W, jt)
    return
  end

  local st = current_station()

  if st then
    -- Station info
    local detail = fetch(config.server .. "/station/" .. st.id)
    local file_id = st.id:match("^(.+)::.+$") or ""
    local connections = fetch(config.server .. "/connections?file=" .. vim.uri_encode(file_id))
    local rows, W, jt = build_info_rows(st.name, st.summary, file_id, detail, connections)
    open_info_popup(st.name, rows, W, jt)
  else
    -- Component (line/file) info
    local line = state.data and state.data.lines and state.data.lines[state.line_idx]
    if not line then return end
    local connections = fetch(config.server .. "/connections?file=" .. vim.uri_encode(line.id))
    local rows, W, jt = build_info_rows(line.name, line.summary, line.id, nil, connections)
    open_info_popup(line.name, rows, W, jt)
  end
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

  local lnum = math.max(1, line_nr or 1)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  vim.schedule(function()
    local max = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(lnum, max), 0 })
    vim.cmd("normal! zz")
  end)
end

-- ─── Keymaps ──────────────────────────────────────────────────────────────────

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
  -- update footer hint
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_config(state.win, {
      footer     = "  i:info  <CR>:zoom-in  j/k:move  b:functions  q:close  ",
      footer_pos = "center",
    })
  end
  redraw()
end

local function zoom_to_functions(crate_id)
  -- crate_id is e.g. "metroscope-indexer"; filter the map to just that crate's files
  local url = config.server .. "/map?crate=" .. vim.uri_encode(crate_id)
  local data = fetch(url)
  if not data then return end
  state.zoom         = "functions"
  state.data         = data
  state.crate_filter = crate_id
  state.line_idx     = 1
  state.station_idx  = 1
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_config(state.win, {
      footer     = "  i:info  <CR>:jump  h/l:move  j/k:line  b:modules  q:close  ",
      footer_pos = "center",
    })
  end
  redraw()
end

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
  map("I", function()
    state.info_pinned = not state.info_pinned
    if state.info_pinned then
      show_info()
      vim.notify("Metroscope: info pinned — navigating updates info panel", vim.log.levels.INFO)
    else
      close_info()
    end
  end)
  map("<Tab>", function()
    if info_win and vim.api.nvim_win_is_valid(info_win) then
      vim.api.nvim_set_current_win(info_win)
    end
  end)
  map("b", function()
    if state.zoom == "functions" then
      zoom_to_modules()
    else
      -- zoom back to functions for the currently focused module
      local m = state.data and state.data.modules and state.data.modules[state.line_idx]
      if m then zoom_to_functions(m.id)
      else zoom_to_functions("") end
    end
  end)
  map("<CR>", function()
    if state.zoom == "modules" then
      local m = state.data and state.data.modules and state.data.modules[state.line_idx]
      if m then zoom_to_functions(m.id) end
    else
      jump_to_code()
    end
  end)
  map("q",     M.close)
  map("<Esc>", M.close)
end

-- ─── Public API ───────────────────────────────────────────────────────────────

function M.close()
  state.info_pinned = false
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

  state.data         = data
  state.zoom         = "functions"
  state.crate_filter = nil
  state.line_idx     = 1
  state.station_idx  = 1

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
  if config.serena_dir then
    cmd = cmd .. " --serena-dir " .. vim.fn.shellescape(config.serena_dir)
  end
  local p = config.prompts or {}
  if p.functions then cmd = cmd .. " --function-prompt " .. vim.fn.shellescape(p.functions) end
  if p.file      then cmd = cmd .. " --file-prompt "     .. vim.fn.shellescape(p.file)      end
  if p.system    then cmd = cmd .. " --system-prompt "   .. vim.fn.shellescape(p.system)    end
  vim.cmd("botright 15split | terminal " .. cmd)
end

function M.setup(opts)
  opts = opts or {}
  if opts.server      then config.server      = opts.server      end
  if opts.serena_dir  then config.serena_dir  = opts.serena_dir  end
  if opts.module_info then config.module_info = opts.module_info end
  if opts.prompts     then config.prompts     = opts.prompts     end
  local leader = opts.leader or "<leader>m"
  vim.keymap.set("n", leader .. "s", M.open, { desc = "Metroscope: open map" })
  vim.keymap.set("n", leader .. "i", function()
    M.index(vim.fn.getcwd(), vim.env.ANTHROPIC_API_KEY)
  end, { desc = "Metroscope: re-index" })
end

return M
