-- Shared state and configuration for metroscope.nvim

local M = {}

M.config = {
	server = "http://127.0.0.1:7777",
	auth_token = nil,
	serena_dir = nil,
	module_info = "detailed", -- "detailed" | "compact"
	prompts = {
		functions = nil,
		file = nil,
		system = nil,
	},
}

M.state = {
	buf = nil,
	win = nil,
	data = nil,
	zoom = "functions", -- "functions" | "modules" | "stations"
	crate_filter = nil,
	line_idx = 1,
	station_idx = 1,
	info_pinned = false,
	project_root = nil,
	sl_stations = nil,
	sl_idx = 1,
	sl_list_buf = nil,
	sl_list_win = nil,
	sl_prev_buf = nil,
	sl_prev_win = nil,
	dim_win = nil,
	quest_counts = {}, -- { ["crate-name"] = N } — populated on map open
}

-- Layout constants (used by render, highlights, info)
M.LABEL_W = 14
M.PAD = 3
M.BOX_MIN = 6
M.CROSS_SYM = "⬡"
M.DASH = "─"
M.ROWS_PER_LINE = 4

return M
