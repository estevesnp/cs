local M = {}

local not_available_msg = "'cs' is not available, will use default options for cswalk"

function M.check()
  local ok, proc = pcall(vim.system, { "cs", "version" })
  if not ok then
    vim.health.warn(not_available_msg)
    return
  end

  local version = proc:wait().stdout
  if version then
    vim.health.ok("'cs' is availabe")
  else
    vim.health.warn(not_available_msg)
  end
end

return M
