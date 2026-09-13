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
---@field continue_on_marker boolean
---@field max_depth number

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
  continue_on_marker = false,
  max_depth = 5,
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
    local config = env.config or {}
    local continue_on_marker = config.continue_on_marker
    if continue_on_marker == nil then
      continue_on_marker = default_opts.continue_on_marker
    end

    cache.env_opts = {
      continue_on_marker = continue_on_marker,
      preview = config.preview or default_opts.preview,
      roots = env.roots or default_opts.roots,
      markers = config.markers or default_opts.markers,
      max_depth = config.max_depth or default_opts.max_depth,
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

---@class cs.ResolvedSearchOpts : cs.lib.SearchOpts
---@field roots string[]
---@field markers string[]
---@field continue_on_marker boolean
---@field max_depth number
---@field preview string
---@field action cs.Action
---@field prompt string

---@class cs.SearchOpts
---dirs to start searching for projects from
---@field roots string[]|nil
---markers to determine if a dir is a project
---@field markers string[]|nil
---continue searching root after finding a marker
---@field continue_on_marker boolean|nil
---max depth for each root when searching for a project
---@field max_depth number|nil
---fzf preview template. e.g.: ls {}
---@field preview string|nil
---action to perform on selected project
---@field action cs.Action|nil
---fzf prompt
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

  local projects = require("cs.lib").search_projects(opts)
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
  return require("cs.lib").search_projects({ roots = roots })
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
