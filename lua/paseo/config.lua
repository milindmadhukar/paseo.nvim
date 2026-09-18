--- Configuration: defaults, user merge, and the accessor everything else uses.
---
--- The table is deliberately small. Options land here only once something
--- actually reads them -- a key that exists but is ignored is worse than no key,
--- because it reads like a promise.

local M = {}

---@class paseo.Config
---@field backend "paseo"|"local"  Where agents run. See README, "Backend seam".
---@field paseo paseo.Config.Paseo
---@field workspaces paseo.Config.Workspaces
---@field review paseo.Config.Review

---@class paseo.Config.Paseo
---@field url string      Daemon WebSocket endpoint the sidecar connects to.
---@field health_url string  Plain HTTP endpoint, used only by :checkhealth.
---@field cli string      Path to the `paseo` binary. One-shot writes only --
---                       it boots Electron per call and costs ~2.4s, so no
---                       interactive path may touch it.

---@class paseo.Config.Workspaces
---@field dir string      Directory, relative to a project root, holding the
---                       assembled worktrees. Flipping this is the one knob
---                       that moves them out of the project tree.

---@class paseo.Config.Review
---@field context integer Lines of context asked of `git diff` when building the
---                       hunk quickfix list. 0 is required: a hunk header's
---                       line numbers only mean "the hunk" at -U0.

---@type paseo.Config
local defaults = {
  backend = "paseo",

  paseo = {
    url = "ws://127.0.0.1:6767/ws",
    health_url = "http://127.0.0.1:6767/api/health",
    cli = "paseo",
  },

  workspaces = {
    dir = ".workspaces",
  },

  review = {
    context = 0,
  },
}

---@type paseo.Config
local config = vim.deepcopy(defaults)

---Merge user options over the defaults.
---@param opts? table
---@return paseo.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.validate("backend", config.backend, function(v)
    return v == "paseo" or v == "local"
  end, '"paseo" or "local"')
  vim.validate("review.context", config.review.context, "number")

  return config
end

---The live config. Safe to call before `setup()`; you get the defaults.
---@return paseo.Config
function M.get()
  return config
end

---The pristine defaults, for docs and tests.
---@return paseo.Config
function M.defaults()
  return vim.deepcopy(defaults)
end

return M
