local M = {}

-- Replace lines [start_line, end_line] (1-indexed, inclusive) in buf with new text.
-- Handles partial first/last line selection (col offsets).
-- The replacement is a single undo step.
function M.replace_selection(buf, start_line, start_col, end_line, end_col, new_text)
  -- nvim_buf_set_text uses 0-indexed lines and byte colf
  local lines = vim.split(new_text, "\n", { plain = true })

  -- Strip trailing empty line that split often produces
  if lines[#lines] == "" then
    table.remove(lines)
  end

  -- Clamp end_col to the actual byte length of the end line to avoid
  -- "out of range" when the selection ends at the last char of a line.
  local end_line_content = vim.api.nvim_buf_get_lines(buf, end_line - 1, end_line, false)[1] or ""
  end_col = math.min(end_col, #end_line_content)

  vim.api.nvim_buf_set_text(buf, start_line - 1, start_col, end_line - 1, end_col, lines)
end

return M
