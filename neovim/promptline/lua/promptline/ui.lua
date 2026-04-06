local M = {}

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function make_win(title, width, height, row, col)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = title and (" " .. title .. " ") or nil,
		title_pos = "center",
	})
	vim.wo[win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
	return buf, win
end

function M.close_float(win)
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
end

function M.show_working(win, buf, msg)
	vim.bo[buf].buftype = ""
	vim.bo[buf].modifiable = true

	local frame = 1
	local timer = vim.loop.new_timer()

	local function render()
		if not vim.api.nvim_buf_is_valid(buf) then
			timer:stop()
			return
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { spinner_frames[frame] .. "  " .. msg })
		frame = (frame % #spinner_frames) + 1
	end

	render()
	timer:start(0, 80, vim.schedule_wrap(render))

	if vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_config(win, { title = " promptline — working… ", title_pos = "center" })
	end
	vim.cmd("stopinsert")
	vim.cmd("wincmd p")

	local stopped = false
	return function()
		if stopped then
			return
		end
		stopped = true
		timer:stop()
		timer:close()
	end
end

local function open_dim_overlay()
  local overlay_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[overlay_buf].bufhidden = "wipe"

  -- Fill with spaces so the highlight covers the whole screen
  local lines = {}
  for _ = 1, vim.o.lines do
    table.insert(lines, string.rep(" ", vim.o.columns))
  end
  vim.api.nvim_buf_set_lines(overlay_buf, 0, -1, false, lines)

  local overlay_win = vim.api.nvim_open_win(overlay_buf, false, {
    relative = "editor",
    width = vim.o.columns,
    height = vim.o.lines,
    row = 0,
    col = 0,
    style = "minimal",
    border = "none",
    zindex = 49,  -- below the explain float (default zindex is 50)
    focusable = false,
  })

  vim.wo[overlay_win].winhl = "Normal:PromptlineDim"
  vim.wo[overlay_win].winblend = 60

  return overlay_win
end

function M.show_explain(win, buf, text)
  vim.bo[buf].buftype = ""
  vim.bo[buf].modifiable = true

  local width = vim.api.nvim_win_get_width(win)
  local wrapped = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    if para == "" then
      table.insert(wrapped, "")
    else
      local pos = 1
      while pos <= #para do
        local chunk = para:sub(pos, pos + width - 3)
        if #chunk == width - 2 and para:sub(pos + width - 2, pos + width - 2) ~= "" then
          local last_space = chunk:match(".*()%s")
          if last_space and last_space > 1 then
            chunk = chunk:sub(1, last_space - 1)
          end
        end
        table.insert(wrapped, chunk)
        pos = pos + #chunk
        if para:sub(pos, pos) == " " then pos = pos + 1 end
      end
    end
  end

  -- Dim overlay behind the explanation
  local overlay_win = open_dim_overlay()

  local height = math.min(#wrapped, math.floor(vim.o.lines * 0.6))
  vim.api.nvim_win_set_config(win, {
    height = height,
    title = " promptline — explanation ",
    title_pos = "center",
    zindex = 50,
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, wrapped)
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.api.nvim_set_current_win(win)

  local function close()
    M.close_float(overlay_win)
    M.close_float(win)
  end
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q",     close, { buffer = buf, nowait = true })
end

-- Open a small secondary float showing the preset list.
-- Returns { win, buf, close() }.
local function open_preset_picker(presets, selected_idx, anchor_row, anchor_col, anchor_width)
	local width = 20
	for _, p in ipairs(presets) do
		width = math.max(width, #p.label + 6)
	end

	-- Position to the right of the input float, same row
	local col = anchor_col + anchor_width + 2
	-- If it would go off screen, put it to the left instead
	if col + width > vim.o.columns then
		col = math.max(0, anchor_col - width - 2)
	end

	local buf, win = make_win("mode", width, #presets, anchor_row, col)

	vim.bo[buf].modifiable = true
	local ns = vim.api.nvim_create_namespace("promptline_presets")

	local function redraw(idx)
		local rows = {}
		for i, p in ipairs(presets) do
			table.insert(rows, string.format(" %s %s", (i == idx) and "›" or " ", p.label))
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		for i in ipairs(presets) do
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
				end_col = #rows[i],
				hl_group = (i == idx) and "PmenuSel" or "Pmenu",
			})
		end
		vim.bo[buf].modifiable = false
	end

	redraw(selected_idx)
	vim.bo[buf].modifiable = false

	return {
		win = win,
		buf = buf,
		redraw = redraw,
		close = function()
			M.close_float(win)
		end,
	}
end

function M.prompt(opts, on_submit, on_cancel)
	local title = opts.title or "Prompt"
	local placeholder = opts.placeholder or ""
	local width = opts.width or 60
	local presets = opts.presets or {}

	-- Center the input float
	local height = 1
	local row = math.floor((vim.o.lines - height) / 2) - 4
	local col = math.floor((vim.o.columns - width) / 2)

	local buf, win = make_win(title, width, height, row, col)
	vim.api.nvim_set_current_win(win)

	vim.bo[buf].buftype = "prompt"
	vim.fn.prompt_setprompt(buf, "")

	-- Placeholder hint
	local hint_ns = vim.api.nvim_create_namespace("promptline_hint")
	if placeholder ~= "" then
		vim.api.nvim_buf_set_extmark(buf, hint_ns, 0, 0, {
			virt_text = { { placeholder, "Comment" } },
			virt_text_pos = "overlay",
			hl_mode = "combine",
		})
	end

	-- Update title hint if presets exist
	if #presets > 0 then
		vim.api.nvim_win_set_config(win, {
			title = " promptline  <C-n/p> mode ",
			title_pos = "center",
		})
	end

	vim.cmd("startinsert")

	vim.api.nvim_create_autocmd("TextChangedI", {
		buffer = buf,
		once = true,
		callback = function()
			vim.api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
		end,
	})

	local submitted = false
	local selected_idx = 1
	local picker = nil -- preset picker window, opened lazily

	local function close_picker()
		if picker then
			picker.close()
			picker = nil
		end
	end

	local function do_cancel()
		if submitted then
			return
		end
		submitted = true
		close_picker()
		M.close_float(win)
		vim.schedule(on_cancel)
	end

	local function cycle(dir)
		if #presets == 0 then
			return
		end
		selected_idx = ((selected_idx - 1 + dir) % #presets) + 1

		if not picker then
			-- Lazy-open the picker on first cycle
			local win_pos = vim.api.nvim_win_get_position(win)
			picker = open_preset_picker(presets, selected_idx, win_pos[1], win_pos[2], width)
		else
			picker.redraw(selected_idx)
		end

		-- Keep focus and cursor in the input window
		vim.api.nvim_set_current_win(win)
		vim.cmd("startinsert!")
	end

	vim.keymap.set("i", "<C-n>", function()
		cycle(1)
	end, { buffer = buf, nowait = true })
	vim.keymap.set("i", "<C-p>", function()
		cycle(-1)
	end, { buffer = buf, nowait = true })

	vim.keymap.set("i", "<CR>", function()
		if submitted then
			return
		end
		submitted = true
		local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
		local text = (lines[1] or ""):gsub("^%s*(.-)%s*$", "%1")
		close_picker()
		vim.schedule(function()
			on_submit({ text = text, preset_idx = selected_idx }, win, buf)
		end)
	end, { buffer = buf, nowait = true })

	vim.keymap.set("i", "<Esc>", do_cancel, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", do_cancel, { buffer = buf, nowait = true })

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if not submitted then
				close_picker()
				vim.schedule(on_cancel)
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			do_cancel()
		end,
	})
end

return M
