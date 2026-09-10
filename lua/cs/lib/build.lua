local log = require("cs.log")

local M = {}

local cache = {
  repo_root = nil,
}

---@return string
local function get_lib_from_zigout()
  if jit.os == "Windows" then
    return "bin/cswalk.dll"
  elseif jit.os == "OSX" then
    return "lib/libcswalk.dylib"
  else
    return "lib/libcswalk.so"
  end
end

local function get_repo_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end

  local script_path = source:match("^(.*[/\\])") or ""
  return script_path .. "../../../"
end

---get cs repo root
---@return string
function M.get_repo_root()
  if cache.repo_root == nil then
    cache.repo_root = get_repo_root()
  end
  return cache.repo_root
end

---get path to cswalk lib
---@param root string?
---@return string
function M.get_lib_path(root)
  root = root or M.get_repo_root()
  return root .. "zig-out/" .. get_lib_from_zigout()
end

---build cswalk
---@param force boolean?
---@return boolean ok
function M.build_cswalk(force)
  local root = M.get_repo_root()
  local lib_path = M.get_lib_path(root)

  if not force and vim.uv.fs_stat(lib_path) ~= nil then
    return true
  end

  log.info("building cswalk...")

  local build_args = { "zig", "build", "-Dlibcswalk", "-Doptimize=ReleaseSafe" }
  local ok, system_res = pcall(vim.system, build_args, { cwd = root })
  if not ok then
    log.error("error building cswalk: %s", system_res)
    return false
  end

  local res = system_res:wait()
  if res.code ~= 0 then
    log.error("build exited with unexpected code: %s", res.code)
    return false
  end

  if vim.uv.fs_stat(lib_path) == nil then
    log.error("lib not found at %s", lib_path)
    return false
  end

  log.info("lib built successfully")
  return true
end

return M
