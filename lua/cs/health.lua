local M = {}

---check if a program is in path and returns something to stdout when called with arg 'version'
---@param program string
---@return boolean ok
local function check_program_version(program)
  local ok, proc = pcall(vim.system, { program, "version" })
  if not ok then
    return false
  end

  return proc:wait().stdout ~= nil
end

function M.check()
  local zig_ok = check_program_version("zig")
  if zig_ok then
    vim.health.ok("'zig' is availabe")
  else
    vim.health.error("'zig' is not available, will not be able to build cswalk")
  end

  local cs_ok = check_program_version("cs")
  if cs_ok then
    vim.health.ok("'cs' is availabe")
  else
    vim.health.warn("'cs' is not available, will use default options for cswalk")
  end
end

return M
