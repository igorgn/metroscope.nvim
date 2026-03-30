-- Info popup for metroscope.nvim

local st   = require("metroscope.state")
local util = require("metroscope.util")

local state     = st.state
local config    = st.config
local LABEL_W   = st.LABEL_W
local PAD       = st.PAD
local BOX_MIN   = st.BOX_MIN
local CROSS_SYM = st.CROSS_SYM

local M = {}

M.info_win    = nil
M.explain_win = nil

function M.close_info()
  if M.info_win and vim.api.nvim_win_is_valid(M.info_win) then
    vim.api.nvim_win_close(M.info_win, true)
  end
  M.info_win = nil
  if M.explain_win and vim.api.nvim_win_is_valid(M.explain_win) then
    vim.api.nvim_win_close(M.explain_win, true)
  end
  M.explain_win = nil
end

-- Compute the buffer column just past the right edge of the focused station box.
local function focused_box_right_col()
  if not state.data then return LABEL_W + 1 + 2 end
  local line = state.data.lines and state.data.lines[state.line_idx]
  if not line or #line.stations == 0 then return LABEL_W + 1 + 2 end

  local col = LABEL_W + 1 + 2  -- indent: label + space + 2 leading dashes
  for si, s in ipairs(line.stations) do
    local label = s.has_cross_line and (s.name .. " " .. CROSS_SYM) or s.name
    local inner = math.max(vim.fn.strdisplaywidth(label) + 2, BOX_MIN)
    local w = inner + 2  -- total box width including borders
    if si == state.station_idx then
      return col + w
    end
    col = col + w + PAD
  end
  return col
end

local function fetch(url)
  local auth = config.auth_token
    and (' -H "Authorization: Bearer ' .. config.auth_token .. '"')
    or  ""
  local handle = io.popen('curl -s --max-time 2' .. auth .. ' "' .. url .. '"')
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  if not result or result == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, result)
  return ok and decoded or nil
end

function M.build_info_rows(title, summary, file_id, detail, connections)
  local W = 52
  local rows = {}
  local jump_targets = {}
  local function push(s, target)
    table.insert(rows, s)
    if target then jump_targets[#rows] = target end
  end
  local function rule() push(string.rep("─", W - 2)) end
  local function blank() push("") end

  if detail and not detail.error then
    local kind = detail.kind or ""
    push(util.pad_right(" " .. title, W - #kind - 3) .. kind .. " ")
    rule()
    blank()

    local summary_text = (detail.summary ~= "" and detail.summary) or "(no summary)"
    for _, wl in ipairs(util.word_wrap(summary_text, W - 4)) do push("  " .. wl) end
    blank()

    if detail.file then
      push("  " .. detail.file .. "  :" .. (detail.line_start or "") .. "–" .. (detail.line_end or ""),
        { file = detail.file, line = detail.line_start })
      blank()
    end

    if detail.calls and #detail.calls > 0 then
      push("  → Calls")
      for _, c in ipairs(detail.calls) do
        local name = util.pad_right("  ▸ " .. c.name, 24)
        local hint = c.summary ~= "" and c.summary:sub(1, W - 26) or ""
        push(name .. (hint ~= "" and "  " .. hint or ""),
          { file = c.file, line = c.line_start })
      end
      blank()
    end

    if detail.called_by and #detail.called_by > 0 then
      push("  ← Called by")
      for _, c in ipairs(detail.called_by) do
        local name = util.pad_right("  ▸ " .. c.name, 24)
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
    for _, wl in ipairs(util.word_wrap(s, W - 4)) do push("  " .. wl) end
    blank()
  end

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

function M.build_module_info_rows(m)
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
  for _, wl in ipairs(util.word_wrap(summary, W - 4)) do push("  " .. wl) end
  blank()

  if config.module_info == "detailed" then
    if #m.calls_into > 0 then
      push("  → Calls into")
      for _, cid in ipairs(m.calls_into) do push("  ▸ " .. cid) end
      blank()
    end
    if #m.called_from > 0 then
      push("  ← Called from")
      for _, cid in ipairs(m.called_from) do push("  ▸ " .. cid) end
      blank()
    end
  end

  return rows, W, jump_targets
end

function M.open_info_popup(title, rows, W, jump_targets, on_close_cb, station_id)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false

  local H = math.min(#rows, vim.o.lines - 4)

  local box_right  = focused_box_right_col()
  local map_pos    = vim.api.nvim_win_get_position(state.win)
  local screen_col = map_pos[2] + 1 + box_right
  local col_offset, anchor
  if screen_col + W + 1 <= vim.o.columns then
    col_offset = box_right + 1
    anchor     = "NW"
  else
    local box_left = LABEL_W + 1 + 2
    col_offset = math.max(0, box_left - W - 2)
    anchor     = "NW"
  end

  local row_offset = -1  -- top border of the focused box

  M.info_win = vim.api.nvim_open_win(buf, false, {
    relative  = "win",
    win       = state.win,
    width     = W,
    height    = H,
    row       = row_offset,
    col       = col_offset,
    anchor    = anchor,
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
      vim.api.nvim_buf_add_highlight(buf, info_ns, "Function",             i - 1, 0, -1)
    elseif line:match("^  ←") then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "Identifier",           i - 1, 0, -1)
    elseif line:match("^  ⬡") then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "MetroscopeCrossLine",  i - 1, 0, -1)
    end
  end

  local arrow_row = 0

  local function draw_arrow(row)
    vim.api.nvim_buf_clear_namespace(buf, arrow_ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, arrow_ns, row, 0, {
      virt_text     = { { "▶", "MetroscopeArrow" } },
      virt_text_pos = "overlay",
      hl_mode       = "combine",
    })
  end

  draw_arrow(arrow_row)

  local function focus_map()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_set_current_win(state.win)
    end
  end

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q",     M.close_info, opts)
  vim.keymap.set("n", "<Esc>", M.close_info, opts)
  vim.keymap.set("n", "<Tab>", focus_map,    opts)
  vim.keymap.set("n", "i",     function() M.close_info(); focus_map() end, opts)
  vim.keymap.set("n", "j", function()
    local max = vim.api.nvim_buf_line_count(buf) - 1
    if arrow_row < max then
      arrow_row = arrow_row + 1
      draw_arrow(arrow_row)
      vim.api.nvim_win_set_cursor(M.info_win, { arrow_row + 1, 0 })
    end
  end, opts)
  vim.keymap.set("n", "k", function()
    if arrow_row > 0 then
      arrow_row = arrow_row - 1
      draw_arrow(arrow_row)
      vim.api.nvim_win_set_cursor(M.info_win, { arrow_row + 1, 0 })
    end
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    local target = jump_targets and jump_targets[arrow_row + 1]
    if not target or not target.file or target.file == "" then return end
    M.close_info()
    if on_close_cb then on_close_cb() end
    util.jump_to_file(target.file, target.line)
  end, opts)

  -- e: open explanation float (only when viewing a station, not a module)
  if station_id then
    vim.keymap.set("n", "e", function()
      M.open_explain_float(station_id, title)
    end, opts)
  end

  if not state.info_pinned then
    vim.schedule(function()
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
      vim.api.nvim_create_autocmd("CursorMoved", {
        buffer   = state.buf,
        once     = true,
        callback = M.close_info,
      })
    end)
  end
end

function M.show_info(current_station_fn, current_module_fn, close_all_fn)
  M.close_info()

  local m = current_module_fn and current_module_fn()
  if m then
    local rows, W, jt = M.build_module_info_rows(m)
    M.open_info_popup(m.name, rows, W, jt, close_all_fn)
    return
  end

  local s = current_station_fn and current_station_fn()
  if s then
    local detail      = fetch(config.server .. "/station/" .. s.id)
    local file_id     = s.id:match("^(.+)::.+$") or ""
    local connections = fetch(config.server .. "/connections?file=" .. vim.uri_encode(file_id))
    local rows, W, jt = M.build_info_rows(s.name, s.summary, file_id, detail, connections)
    M.open_info_popup(s.name, rows, W, jt, close_all_fn, s.id)
  else
    local line = state.data and state.data.lines and state.data.lines[state.line_idx]
    if not line then return end
    local connections = fetch(config.server .. "/connections?file=" .. vim.uri_encode(line.id))
    local rows, W, jt = M.build_info_rows(line.name, line.summary, line.id, nil, connections)
    M.open_info_popup(line.name, rows, W, jt, close_all_fn)
  end
end

-- Open a floating window showing the detailed explanation for a station.
-- `station_id` is the full id string; explanation is fetched from the server.
-- open_explain_float: show explanation for a station.
-- If `anchor_win` is provided, the float is anchored to the top-right corner
-- of that window. Otherwise it opens centered on the editor.
function M.open_explain_float(station_id, station_name, anchor_win)
  local detail = fetch(config.server .. "/station/" .. station_id)
  local explanation = detail and detail.explanation
  if not explanation or explanation == "" then
    explanation = "(no explanation available — re-index to generate)"
  end

  local W = 64
  local wrapped = {}
  -- word-wrap the explanation into W-4 wide lines
  local remaining = explanation
  while vim.fn.strdisplaywidth(remaining) > W - 4 do
    local cut = remaining:sub(1, W - 4):match("^(.+)%s") or remaining:sub(1, W - 4)
    table.insert(wrapped, "  " .. cut)
    remaining = vim.trim(remaining:sub(#cut + 1))
  end
  if remaining ~= "" then table.insert(wrapped, "  " .. remaining) end

  local rows = { "" }
  for _, l in ipairs(wrapped) do table.insert(rows, l) end
  table.insert(rows, "")

  local H = math.min(#rows + 2, vim.o.lines - 4)

  local win_config
  if anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
    local pw = vim.api.nvim_win_get_width(anchor_win)
    win_config = {
      relative  = "win",
      win       = anchor_win,
      anchor    = "NE",
      row       = 0,
      col       = pw,   -- NE anchor: col is the right edge of the float
      width     = math.min(W, pw),
      height    = H,
      style     = "minimal",
      border    = "rounded",
      title     = "  explain: " .. (station_name or station_id) .. "  ",
      title_pos = "center",
      footer     = "  y:yank  q/<Esc>:close  ",
      footer_pos = "center",
      zindex    = 150,
    }
  else
    local erow = math.floor((vim.o.lines - H) / 2)
    local ecol = math.floor((vim.o.columns - W) / 2)
    win_config = {
      relative  = "editor",
      width     = W,
      height    = H,
      row       = erow,
      col       = ecol,
      style     = "minimal",
      border    = "rounded",
      title     = "  explain: " .. (station_name or station_id) .. "  ",
      title_pos = "center",
      footer     = "  y:yank  q/<Esc>:close  ",
      footer_pos = "center",
      zindex    = 150,
    }
  end

  -- Toggle: close if already open
  if M.explain_win and vim.api.nvim_win_is_valid(M.explain_win) then
    vim.api.nvim_win_close(M.explain_win, true)
    M.explain_win = nil
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false

  -- enter=false: cursor stays in the calling window
  M.explain_win = vim.api.nvim_open_win(buf, false, win_config)

  local opts = { buffer = buf, nowait = true, silent = true }
  local function close()
    if M.explain_win and vim.api.nvim_win_is_valid(M.explain_win) then
      vim.api.nvim_win_close(M.explain_win, true)
    end
    M.explain_win = nil
  end
  vim.keymap.set("n", "q",     close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
  -- y: yank explanation to system clipboard
  vim.keymap.set("n", "y", function()
    vim.fn.setreg("+", explanation)
    vim.notify("Explanation copied to clipboard", vim.log.levels.INFO)
  end, opts)
end

return M
