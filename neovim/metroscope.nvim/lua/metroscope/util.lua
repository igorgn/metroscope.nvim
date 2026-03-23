-- Utility helpers for metroscope.nvim

local M = {}

function M.pad_right(s, n)
  local len = vim.fn.strdisplaywidth(s)
  return len >= n and s or (s .. string.rep(" ", n - len))
end

function M.dashes(n)
  local DASH = "─"
  return string.rep(DASH, math.max(0, n))
end

function M.word_wrap(s, w)
  local lines = {}
  while vim.fn.strdisplaywidth(s) > w do
    local cut = s:sub(1, w):match("^(.+)%s") or s:sub(1, w)
    table.insert(lines, cut)
    s = vim.trim(s:sub(#cut + 1))
  end
  if s ~= "" then table.insert(lines, s) end
  return lines
end

-- Find a non-metroscope window to use for jumping to code
function M.find_edit_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "metroscope" then
      return w
    end
  end
  return nil
end

-- Open a file at a given line number, closing metroscope first
function M.jump_to_file(abs_file, lnum)
  lnum = math.max(1, lnum or 1)
  local w = M.find_edit_win()
  if w then vim.api.nvim_set_current_win(w) end
  vim.cmd("edit " .. vim.fn.fnameescape(abs_file))
  vim.schedule(function()
    local max = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(lnum, max), 0 })
    vim.cmd("normal! zz")
  end)
end

return M
