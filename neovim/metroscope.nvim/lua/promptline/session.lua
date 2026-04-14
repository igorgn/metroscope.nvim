local M = {}

-- sessions keyed by "buf:label"
local sessions = {}

local function key(buf, label)
  return tostring(buf) .. ":" .. label
end

local function get_or_create(buf, label)
  local k = key(buf, label)
  if not sessions[k] then
    sessions[k] = { history = {}, pending = false }
  end
  return sessions[k]
end

function M.setup(config)
  local reset_keymap = config.session and config.session.reset_keymap or "<leader>sr"
  vim.keymap.set("n", reset_keymap, function()
    local buf = vim.api.nvim_get_current_buf()
    M.reset(buf)
    vim.notify("promptline: chat history cleared", vim.log.levels.INFO)
  end, { desc = "Promptline: reset chat history for current buffer" })
end

function M.get(buf, label)
  return get_or_create(buf, label)
end

function M.append_user(buf, label, content)
  local sess = get_or_create(buf, label)
  table.insert(sess.history, { role = "user", content = content })
end

function M.append_assistant(buf, label, content)
  local sess = get_or_create(buf, label)
  table.insert(sess.history, { role = "assistant", content = content })
end

function M.get_history(buf, label)
  return get_or_create(buf, label).history
end

function M.reset(buf)
  local prefix = tostring(buf) .. ":"
  for k in pairs(sessions) do
    if k:sub(1, #prefix) == prefix then
      sessions[k] = nil
    end
  end
end

return M
