-- Window creation helpers for metroscope.nvim

local st = require("metroscope.state")

local M = {}

function M.open_dim_win()
  vim.api.nvim_set_hl(0, "MetroscopeDim", { bg = "#000000" })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width    = vim.o.columns,
    height   = vim.o.lines,
    row      = 0,
    col      = 0,
    style    = "minimal",
    zindex   = 10,
  })
  vim.wo[win].winblend = 70
  vim.api.nvim_win_set_option(win, "winhighlight", "Normal:MetroscopeDim")
  return win
end

function M.open_window()
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
    footer    = "  i:info  <CR>:stations  h/l:move  j/k:line  b:modules  q:close  ",
    footer_pos = "center",
    zindex    = 50,
  })

  vim.wo[win].wrap       = false
  vim.wo[win].cursorline = false
  vim.wo[win].number     = false
  vim.wo[win].signcolumn = "no"

  return buf, win
end

return M
