local M = {}

---@param level integer
---@param fmt string
---@param ... any
local function log(level, fmt, ...)
  local msg = string.format("cs: " .. fmt, ...)
  vim.notify(msg, level)
end

---@param fmt string
---@param ... any
function M.info(fmt, ...)
  log(vim.log.levels.INFO, fmt, ...)
end

---@param fmt string
---@param ... any
function M.error(fmt, ...)
  log(vim.log.levels.ERROR, fmt, ...)
end

return M
