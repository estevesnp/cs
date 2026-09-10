local ffi = require("ffi")

local log = require("cs.log")
local build = require("cs.lib.build")

local M = {}

local cache = {
	lib = nil,
}

---get libcswalk. if not present, builds and then links it.
---@return ffi.namespace*|nil
local function get_libcswalk()
	if cache.lib then
		return cache.lib
	end

	if not build.build_cswalk() then
		log.error("error building cswalk, aborting linking the library")
		return
	end

	local header_path = build.get_repo_root() .. "src/walk/ffi/include/cswalk.h"
	local header_file = assert(io.open(header_path, "r"), "error finding cswalk header")
	local full_header = header_file:read("*a")
	header_file:close()

	local truncated_header = full_header:gsub("[^\n]*\n", function(line)
		if line:match("^%s*#") then
			return ""
		end
		return line
	end)

	ffi.cdef(truncated_header)

	cache.lib = ffi.load(build.get_lib_path())
	return cache.lib
end

---find projects for roots
---@param roots string[]|nil
---@return string[]
function M.search_projects(roots)
	roots = roots or {}
	if #roots == 0 then
		-- TODO - get default roots
		return {}
	end

	local lib = get_libcswalk()
	if not lib then
    -- TODO - what do
		return {}
	end

	local root_paths = ffi.new("const char *[?]", #roots)

	for i, path in ipairs(roots) do
		root_paths[i - 1] = path
	end

	local opts = ffi.new("CsSearchOpts")
	opts.enable_logging = true

	local result = lib.cs_search_projects(root_paths, #roots, opts)
	if not result.ok then
		return {}
	end

	local projects = {}

	for i = 0, result.count - 1 do
		projects[i + 1] = ffi.string(result.paths[i])
	end

	lib.cs_free_projects(result.paths, result.count)

	return projects
end

return M
