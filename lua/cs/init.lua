local log = require("cs.log")

local M = {}

local cache = {
  ---@type cs.ResolvedSearchOpts|nil
  env_opts = nil,
}

---@class cs.Env
---@field config cs.Config
---@field roots string[]

---@class cs.Config
---@field preview string

---@return cs.Env|nil
local function get_cs_env()
  local args = { "cs", "env", "--full" }
  local ok, sys_res = pcall(vim.system, args)
  if not ok then
    return nil
  end

  local res = sys_res:wait()
  if res.code ~= 0 then
    return nil
  end

  local stdout = res.stdout
  if not stdout then
    return nil
  end

  local env
  ok, env = pcall(vim.json.decode, stdout)
  if not ok then
    return nil
  end

  return env
end

---@type cs.ResolvedSearchOpts
local default_opts = {
  preview = jit.os == "Windows" and "dir {}" or "ls {}",
  roots = {},
  action = "open",
}

---@return cs.ResolvedSearchOpts
local function get_env_opts()
  if cache.env_opts then
    return cache.env_opts
  end

  local env = get_cs_env()
  if not env then
    cache.env_opts = default_opts
  else
    cache.env_opts = {
      preview = (env.config and env.config.preview) or default_opts.preview,
      roots = env.roots or default_opts.roots,
      action = default_opts.action,
    }
  end

  return cache.env_opts
end

---@class cs.ResolvedSearchOpts
---@field roots string[]
---@field preview string
---@field action cs.Action

---@param opts cs.SearchOpts|nil
---@return cs.ResolvedSearchOpts
local function resolve_opts(opts)
  local env_opts = get_env_opts()
  if not opts then
    return env_opts
  end
  return vim.tbl_extend("force", env_opts, opts)
end

---@type table<cs.Action, fun(selected: string[])>
local action_cb_map = {
  open = function(selected)
    vim.cmd("e " .. selected[1])
  end,
  cd = function(selected)
    vim.cmd("cd " .. selected[1])
    vim.cmd("e " .. selected[1])
  end,
  tab = function(selected)
    vim.cmd("tabnew " .. selected[1])
    vim.cmd("tcd " .. selected[1])
    vim.cmd("e " .. selected[1])
  end,
}

---@alias cs.Action "cd" | "tab" | "open"

---@class cs.SearchOpts
---@field roots string[]|nil
---@field preview string|nil
---@field action cs.Action|nil

---search projects
---@param search_opts cs.SearchOpts|nil
function M.search_projects(search_opts)
  local opts = resolve_opts(search_opts)

  if #opts.roots == 0 then
    log.warn("no roots found")
    return
  end

  local cb = action_cb_map[opts.action]
  if not cb then
    log.warn("invalid action: %s", opts.action)
    return
  end

  local projects = require("cs.lib").search_projects(opts.roots)
  if #projects == 0 then
    log.warn("no projects found")
    return
  end

  require("fzf-lua").fzf_exec(projects, {
    preview = opts.preview,
    actions = {
      default = cb,
    },
  })
end

---search and return projects
---@param roots string[]|nil
function M.list_projects(roots)
  roots = roots or {}
  if #roots == 0 then
    roots = get_env_opts().roots
  end
  if #roots == 0 then
    log.warn("no roots found")
    return {}
  end
  return require("cs.lib").search_projects(roots)
end

---set default opts
---@param search_opts cs.SearchOpts|nil
function M.setup(search_opts)
  if not search_opts then
    return
  end
  default_opts = vim.tbl_extend("force", default_opts, search_opts)
end

return M
