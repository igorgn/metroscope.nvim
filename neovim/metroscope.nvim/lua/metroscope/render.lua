-- Rendering: box drawing, map and module map rendering

local st = require("metroscope.state")
local util = require("metroscope.util")

local state = st.state
local LABEL_W = st.LABEL_W
local PAD = st.PAD
local BOX_MIN = st.BOX_MIN
local CROSS_SYM = st.CROSS_SYM
local ROWS_PER_LINE = st.ROWS_PER_LINE

local M = {}

--[[
Each station is a box:
  ┌──────────────┐
  │ station_name │
  └──────────────┘
Focused:
  ╔══════════════╗
  ║ station_name ║
  ╚══════════════╝
]]

function M.box(name, focused, cross)
  local label = cross and (name .. " " .. CROSS_SYM) or name
  local inner = math.max(vim.fn.strdisplaywidth(label) + 2, BOX_MIN)
  local pad_l = " "
  local pad_r = string.rep(" ", inner - vim.fn.strdisplaywidth(label) - 1)

  if focused then
    return {
      "╔" .. string.rep("═", inner) .. "╗",
      "║" .. pad_l .. label .. pad_r .. "║",
      "╚" .. string.rep("═", inner) .. "╝",
    },
      inner + 2
  else
    return {
      "┌" .. string.rep("─", inner) .. "┐",
      "│" .. pad_l .. label .. pad_r .. "│",
      "└" .. string.rep("─", inner) .. "┘",
    },
      inner + 2
  end
end

local function crate_id_of(file_id)
  -- "crates/metroscope-indexer/src/foo.rs" -> "metroscope-indexer"
  local crate = file_id:match("^crates/([^/]+)/")
  return crate or "root"
end

function M.render_map(data)
  if not data or not data.lines then
    return {}
  end

  local out = {}

  for li, line in ipairs(data.lines) do
    local crate_id = crate_id_of(line.id or "")
    local count = state.quest_counts and state.quest_counts[crate_id]
    local badge = (count and count > 0) and ("⚔" .. count) or nil
    local base_name = "[" .. line.name .. "]"
    local label
    if badge then
      -- Pad so badge fits within LABEL_W
      local space = LABEL_W - vim.fn.strdisplaywidth(base_name) - vim.fn.strdisplaywidth(badge) - 1
      label = base_name .. string.rep(" ", math.max(1, space)) .. badge
    else
      label = util.pad_right(base_name, LABEL_W)
    end

    if #line.stations == 0 then
      table.insert(out, label .. " " .. util.dashes(8))
      table.insert(out, "")
      table.insert(out, "")
      table.insert(out, "")
    else
      local boxes = {}
      local widths = {}
      for si, s in ipairs(line.stations) do
        local focused = (state.line_idx == li and state.station_idx == si)
        local b, w = M.box(s.name, focused, s.has_cross_line)
        boxes[si] = b
        widths[si] = w
      end

      local lead = 2
      local indent = string.rep(" ", LABEL_W + 1 + lead)
      local top_row = indent
      local mid_row = label .. " " .. util.dashes(lead)
      local bot_row = indent

      for si, b in ipairs(boxes) do
        top_row = top_row .. b[1]
        mid_row = mid_row .. b[2]
        bot_row = bot_row .. b[3]
        if si < #boxes then
          top_row = top_row .. string.rep(" ", PAD)
          mid_row = mid_row .. util.dashes(PAD)
          bot_row = bot_row .. string.rep(" ", PAD)
        end
      end

      table.insert(out, top_row)
      table.insert(out, mid_row)
      table.insert(out, bot_row)
      table.insert(out, "")
    end
  end

  return out
end

function M.render_module_map(data)
  if not data or not data.modules then
    return {}
  end

  local modules = data.modules
  local out = {}

  local mod_idx = {}
  for i, m in ipairs(modules) do
    mod_idx[m.id] = i
  end

  for mi, m in ipairs(modules) do
    local focused = (state.zoom == "modules" and state.line_idx == mi)
    local label = util.pad_right("[" .. m.name .. "]", LABEL_W)
    local count = "(" .. m.station_count .. ")"
    local b, _ = M.box(m.name .. "  " .. count, focused, #m.calls_into > 0)

    local lead = 2
    local indent = string.rep(" ", LABEL_W + 1 + lead)
    local top_row = indent .. b[1]
    local mid_row = label .. " " .. util.dashes(lead) .. b[2]
    local bot_row = indent .. b[3]

    local conn_rows = {}
    for _, target_id in ipairs(m.calls_into) do
      local ti = mod_idx[target_id]
      if ti and ti > mi then
        table.insert(conn_rows, indent .. "│  calls → " .. (modules[ti] and modules[ti].name or target_id))
      end
    end

    table.insert(out, top_row)
    table.insert(out, mid_row)
    table.insert(out, bot_row)
    for _, cr in ipairs(conn_rows) do
      table.insert(out, cr)
    end
    table.insert(out, "")
  end

  return out
end

return M
