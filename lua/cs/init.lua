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
---@field markers string[]
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
  markers = { ".git", ".jj" },
  action = "open",
  prompt = "choose a project> ",
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
      markers = (env.config and env.config.markers) or default_opts.markers,
      action = default_opts.action,
      prompt = default_opts.prompt,
    }
  end

  return cache.env_opts
end

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
    vim.cmd.edit(selected[1])
  end,
  vsplit = function(selected)
    vim.cmd("vsplit | wincmd l")
    vim.cmd.edit(selected[1])
    vim.cmd.bcd(selected[1])
  end,
  tab = function(selected)
    vim.cmd.tabnew(selected[1])
    vim.cmd.edit(selected[1])
    vim.cmd.tcd(selected[1])
  end,
  cd = function(selected)
    vim.cmd.edit(selected[1])
    vim.cmd.cd(selected[1])
  end,
}

---@class cs.ResolvedSearchOpts
---@field roots string[]
---@field markers string[]
---@field preview string
---@field action cs.Action
---@field prompt string

---@class cs.SearchOpts
---@field roots string[]|nil
---@field markers string[]|nil
---@field preview string|nil
---@field action cs.Action|nil
---@field prompt string|nil

---@alias cs.Action "open" | "vsplit" | "tab" | "cd"

---search projects inside fzf picker
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
    prompt = opts.prompt,
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

---set default opts. opts from `cs env --full` still override these.
---@param search_opts cs.SearchOpts|nil
function M.setup(search_opts)
  if not search_opts then
    return
  end
  default_opts = vim.tbl_extend("force", default_opts, search_opts)
end

return M
