local lib = require("cs.lib")

local M = {}

function M.search_projects()
	local env_str = vim.system({ "cs", "env" }):wait()
	local env = vim.json.decode(env_str.stdout or "{}")

	local config = env.config or {}
	local preview = config.preview or "ls {}"
	local roots = env.roots or {}

	local projects = lib.search_projects(roots)
	require("fzf-lua").fzf_exec(projects, {
		preview = preview,
		actions = {
			["default"] = function(selected)
				vim.print("selected:", selected)
			end,
		},
	})
end

return M
