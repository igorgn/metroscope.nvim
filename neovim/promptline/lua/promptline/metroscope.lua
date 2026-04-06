-- Fetches codebase context from the Metroscope server for a given file+line.
-- Returns a context string to inject into the AI prompt, or nil if unavailable.

local M = {}

M.port = 7777

-- Synchronous curl call (runs in a blocking fashion via vim.fn.system).
-- Only used at trigger time, not in a hot path, so blocking is acceptable.
local function get(url)
	local out = vim.fn.system({ "curl", "-sf", "--max-time", "1", url })
	if vim.v.shell_error ~= 0 or not out or out == "" then
		return nil
	end
	local ok, decoded = pcall(vim.fn.json_decode, out)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

-- Returns a relative file path suitable for the Metroscope /map endpoint.
-- Strips the project root prefix if the server is serving from the same root.
local function rel_path(bufname)
	-- Use the buffer name as-is; the server accepts both absolute and relative.
	return bufname
end

function M.fetch_context(buf, line)
	local bufname = vim.api.nvim_buf_get_name(buf)
	if bufname == "" then
		return nil
	end

	local base = "http://localhost:" .. M.port

	-- Step 1: resolve the station at file+line
	local file_enc = vim.uri_encode(rel_path(bufname), "rfc2396")
	local map = get(base .. "/map?file=" .. file_enc .. "&line=" .. line)
	if not map then
		return nil
	end

	local station_id = map.focused_station and map.focused_station.id
	if not station_id then
		return nil
	end

	-- Step 2: fetch full station detail
	local station = get(base .. "/station/" .. station_id)
	if not station or station.error then
		return nil
	end

	-- Build a compact context block
	local parts = {}

	table.insert(parts, "## Codebase context (from Metroscope)")
	table.insert(parts, "Function: " .. (station.name or station_id))
	table.insert(parts, "File: " .. (station.file or ""))
	if station.summary and station.summary ~= "" then
		table.insert(parts, "Summary: " .. station.summary)
	end
	if station.explanation and station.explanation ~= "" then
		table.insert(parts, "Explanation: " .. station.explanation)
	end
	if station.line_summary and station.line_summary ~= "" then
		table.insert(parts, "Module: " .. station.line_summary)
	end

	if station.calls and #station.calls > 0 then
		local names = {}
		for _, c in ipairs(station.calls) do
			table.insert(names, c.name .. " (" .. c.summary .. ")")
		end
		table.insert(parts, "Calls: " .. table.concat(names, ", "))
	end

	if station.called_by and #station.called_by > 0 then
		local names = {}
		for _, c in ipairs(station.called_by) do
			table.insert(names, c.name .. " (" .. c.summary .. ")")
		end
		table.insert(parts, "Called by: " .. table.concat(names, ", "))
	end

	return table.concat(parts, "\n")
end

return M
