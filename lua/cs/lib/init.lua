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

---@param arr string[]
---@return table
local function to_c_string_arr(arr)
  local c_arr = ffi.new("const char *[?]", #arr)

  for i, str in ipairs(arr) do
    c_arr[i - 1] = str
  end

  return c_arr
end

---@class cs.lib.SearchOpts
---@field roots string[]|nil
---@field markers string[]|nil
---@field continue_on_marker boolean|nil
---@field max_depth number|nil

---find projects for roots
---@param opts cs.lib.SearchOpts
---@return string[]
function M.search_projects(opts)
  opts.roots = opts.roots or {}
  opts.markers = opts.markers or {}
  if opts.continue_on_marker == nil then
    opts.continue_on_marker = false
  end

  if #opts.roots == 0 then
    return {}
  end

  local lib = get_libcswalk()
  if not lib then
    log.error("unable to load libcswalk")
    return {}
  end

  local cs_opts = ffi.new("CsSearchOpts")

  ---@diagnostic disable: inject-field
  cs_opts.enable_logging = true
  cs_opts.project_markers = to_c_string_arr(opts.markers)
  cs_opts.markers_count = #opts.markers
  cs_opts.continue_on_marker = opts.continue_on_marker
  cs_opts.max_depth = opts.max_depth

  local result = lib.cs_search_projects(to_c_string_arr(opts.roots), #opts.roots, cs_opts)
  if not result.ok then
    lib.cs_free_projects(result.handle)
    return {}
  end

  local projects = {}

  for i = 0, result.count - 1 do
    projects[i + 1] = ffi.string(result.paths[i])
  end

  lib.cs_free_projects(result.handle)

  return projects
end

return M
