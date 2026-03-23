-- Highlight groups and buffer highlight application

local st    = require("metroscope.state")

local state     = st.state
local LABEL_W   = st.LABEL_W
local CROSS_SYM = st.CROSS_SYM
local ROWS_PER_LINE = st.ROWS_PER_LINE

local M = {}

local ns = vim.api.nvim_create_namespace("metroscope")

function M.setup()
  vim.api.nvim_set_hl(0, "MetroscopeFocusedName", { bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeArrow",       { bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeCrossLine",   { fg = "#FF6B6B", bold = true })
  vim.api.nvim_set_hl(0, "MetroscopeTrack",       { fg = "#555555" })
  vim.api.nvim_set_hl(0, "MetroscopeStatusKey",   { fg = "#888888" })
end

function M.apply()
  if not state.buf or not state.data then return end
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

  if state.zoom == "modules" then
    for mi, m in ipairs(state.data.modules or {}) do
      local base    = (mi - 1) * ROWS_PER_LINE
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
              mid_row, open_b - 1 + #"║", close_b - 1)
          end
        end
      end

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
    local base    = (li - 1) * ROWS_PER_LINE
    local mid_row = base + 1
    local hl_name = "MetroscopeLine" .. li
    vim.api.nvim_set_hl(0, hl_name, { fg = line.color, bold = true })
    vim.api.nvim_buf_add_highlight(state.buf, ns, hl_name, mid_row, 0, LABEL_W)

    for si, s in ipairs(line.stations) do
      local focused = (state.line_idx == li and state.station_idx == si)

      if focused then
        local mid_text = vim.api.nvim_buf_get_lines(state.buf, base + 1, base + 2, false)[1] or ""
        local open_b = mid_text:find("║", 1, true)
        if open_b then
          local close_b = mid_text:find("║", open_b + #"║", true)
          if close_b then
            vim.api.nvim_buf_add_highlight(
              state.buf, ns, "MetroscopeFocusedName",
              base + 1, open_b - 1 + #"║", close_b - 1)
          end
        end
      end

      if s.has_cross_line then
        local mid_text = vim.api.nvim_buf_get_lines(state.buf, base + 1, base + 2, false)[1] or ""
        local pos = 1
        while true do
          local p = mid_text:find(CROSS_SYM, pos, true)
          if not p then break end
          vim.api.nvim_buf_add_highlight(
            state.buf, ns, "MetroscopeCrossLine",
            base + 1, p - 1, p - 1 + #CROSS_SYM)
          pos = p + #CROSS_SYM
        end
      end
    end
  end
end

return M
