-- Navigation helpers for metroscope.nvim

local st = require("metroscope.state")

local state = st.state

local M = {}

-- Dependency injection: redraw_fn is injected by init.lua to avoid circular deps
local redraw_fn = nil
function M.set_redraw(fn)
  redraw_fn = fn
end

function M.current_station()
  if not state.data then
    return nil
  end
  if state.zoom == "modules" then
    return nil
  end
  local line = state.data.lines and state.data.lines[state.line_idx]
  if not line then
    return nil
  end
  return line.stations[state.station_idx]
end

function M.current_module()
  if not state.data then
    return nil
  end
  if state.zoom ~= "modules" then
    return nil
  end
  return state.data.modules and state.data.modules[state.line_idx]
end

function M.move_right()
  local line = state.data and state.data.lines and state.data.lines[state.line_idx]
  if line and state.station_idx < #line.stations then
    state.station_idx = state.station_idx + 1
    if redraw_fn then
      redraw_fn()
    end
  end
end

function M.move_left()
  if state.station_idx > 1 then
    state.station_idx = state.station_idx - 1
    if redraw_fn then
      redraw_fn()
    end
  end
end

function M.move_down()
  if not state.data then
    return
  end
  local items = state.zoom == "modules" and state.data.modules or state.data.lines
  if not items then
    return
  end
  if state.line_idx < #items then
    state.line_idx = state.line_idx + 1
    if state.zoom ~= "modules" then
      local line = items[state.line_idx]
      state.station_idx = math.min(state.station_idx, math.max(1, #line.stations))
    end
    if redraw_fn then
      redraw_fn()
    end
  end
end

function M.move_up()
  if not state.data then
    return
  end
  if state.line_idx > 1 then
    state.line_idx = state.line_idx - 1
    if state.zoom ~= "modules" then
      local items = state.data.lines
      if items then
        local line = items[state.line_idx]
        state.station_idx = math.min(state.station_idx, math.max(1, #line.stations))
      end
    end
    if redraw_fn then
      redraw_fn()
    end
  end
end

return M
