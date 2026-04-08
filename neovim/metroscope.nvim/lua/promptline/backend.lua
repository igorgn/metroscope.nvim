local M = {}

-- Run a command async, collect stdout, call on_done(output, err)
local function run_async(cmd, on_done)
  local output = {}
  local stderr = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(output, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        on_done(nil, table.concat(stderr, "\n"))
      else
        on_done(table.concat(output, "\n"), nil)
      end
    end,
  })
end

-- Build the full prompt sent to the model
local function build_prompt(config, selection, user_prompt, diagnostics, metro_context)
  local prompt = config.system_prompt

  if metro_context then
    prompt = prompt .. "\n\n" .. metro_context
  end

  prompt = prompt .. "\n\nHere is the text to edit:\n" .. selection

  if diagnostics then
    prompt = prompt .. "\n\nThe following LSP diagnostics (errors/warnings) apply to this code:\n" .. diagnostics
  end

  prompt = prompt
    .. "\n\nInstruction: "
    .. user_prompt
    .. "\n\nRespond with ONLY the edited text. No explanations, no markdown code fences, no extra commentary."

  return prompt
end

function M.run_claude_cli(config, selection, user_prompt, diagnostics, metro_context, on_done)
  local prompt = build_prompt(config, selection, user_prompt, diagnostics, metro_context)

  local cmd = {
    "claude",
    "--no-session-persistence", -- don't save this call to session history
    "-p",
    prompt,
    "--output-format",
    "text",
  }

  run_async(cmd, on_done)
end

function M.run_anthropic_api(config, selection, user_prompt, diagnostics, metro_context, on_done)
  local api_key = config.api_key or vim.env.ANTHROPIC_API_KEY
  if not api_key then
    on_done(nil, "ANTHROPIC_API_KEY not set")
    return
  end

  local prompt = build_prompt(config, selection, user_prompt, diagnostics, metro_context)

  local body = vim.fn.json_encode({
    model = config.model,
    max_tokens = config.max_tokens,
    messages = {
      { role = "user", content = prompt },
    },
  })

  local tmpfile = vim.fn.tempname()
  local f = io.open(tmpfile, "w")
  f:write(body)
  f:close()

  local cmd = {
    "curl",
    "-s",
    "-X",
    "POST",
    "https://api.anthropic.com/v1/messages",
    "-H",
    "Content-Type: application/json",
    "-H",
    "x-api-key: " .. api_key,
    "-H",
    "anthropic-version: 2023-06-01",
    "-d",
    "@" .. tmpfile,
  }

  run_async(cmd, function(output, err)
    vim.fn.delete(tmpfile)
    if err then
      on_done(nil, err)
      return
    end
    local ok, decoded = pcall(vim.fn.json_decode, output)
    if not ok then
      on_done(nil, "Failed to parse API response: " .. tostring(output))
      return
    end
    if decoded.error then
      on_done(nil, decoded.error.message or "API error")
      return
    end
    local text = decoded.content and decoded.content[1] and decoded.content[1].text
    if not text then
      on_done(nil, "Unexpected API response shape")
      return
    end
    on_done(text, nil)
  end)
end

function M.run_copilot_chat(config, selection, user_prompt, diagnostics, metro_context, on_done)
  local ok, CopilotChat = pcall(require, "CopilotChat")
  if not ok then
    on_done(nil, "CopilotChat not available")
    return
  end

  local full_prompt = build_prompt(config, selection, user_prompt, diagnostics, metro_context)

  local ask_ok, ask_err = pcall(function()
    CopilotChat.ask(full_prompt, {
      headless = true,
      callback = function(response)
        local text = type(response) == "table" and response.content or response
        on_done(text, nil)
      end,
    })
  end)
  if not ask_ok then
    on_done(nil, "CopilotChat error: " .. tostring(ask_err))
  end
end

function M.run(config, selection, user_prompt, diagnostics, metro_context, on_done)
  if config.backend == "anthropic_api" then
    M.run_anthropic_api(config, selection, user_prompt, diagnostics, metro_context, on_done)
  elseif config.backend == "copilot_chat" then
    M.run_copilot_chat(config, selection, user_prompt, diagnostics, metro_context, on_done)
  else
    M.run_claude_cli(config, selection, user_prompt, diagnostics, metro_context, on_done)
  end
end

return M
