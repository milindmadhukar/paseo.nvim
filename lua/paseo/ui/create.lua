--- Provider selection and the settings review shown before a new agent exists.
--- The daemon supplies every choice. This module owns no persistent preference:
--- `preference` stores one in config for the current Neovim process.

local bridge = require "paseo.bridge"
local config = require "paseo.config"

local M = {}

local function current_root()
  local chat = require("paseo.ui.chat").current()
  return chat and chat.root or assert(vim.uv.cwd())
end

---How long a kept catalogue is answered from before it is asked for again
---(in the background: the kept one is still what you see). Models come and
---go on the scale of a provider update, not of a keypress.
M.CATALOGUE_TTL = 5 * 60 * 1000

---Where the catalogue for `cwd` on `host_id` is kept in |paseo.store|.
---@param cwd string
---@param host_id? string
---@return string
function M.catalogue_key(cwd, host_id)
  local host = require("paseo.hosts").get(host_id)
  return ("providers\0%s\0%s"):format(host and host.id or tostring(host_id), cwd)
end

---A catalogue still discovering -- any provider `loading` -- is handed over
---but not kept: the next open should ask again rather than show it.
---@param entries table[]|nil
---@return boolean
local function settled(entries)
  for _, entry in ipairs(entries or {}) do
    if entry.status == "loading" then
      return false
    end
  end
  return entries ~= nil
end

---The provider catalogue as the daemon reports it, uncached.
---@param cwd string
---@param host_id? string
---@param done fun(entries: table[]|nil, err: string|nil, keep?: boolean)
function M.fetch_catalogue(cwd, host_id, done)
  bridge.ensure(function(err)
    if err then
      return done(nil, err)
    end
    bridge.request("providers", { cwd = cwd, hostId = host_id }, function(fetch_err, result)
      local entries = result and result.entries or nil
      done(entries, fetch_err, settled(entries))
    end, host_id)
  end, host_id)
end

---From |paseo.store|: the kept catalogue at once, the daemon's when there is
---none. The new-task screen and its terminal presets ask together, and share
---one request. A copy each, so a caller's draft cannot edit the kept one.
local function fetch_catalogue(cwd, callback, host_id)
  require("paseo.store").get(M.catalogue_key(cwd, host_id), M.CATALOGUE_TTL, function(done)
    M.fetch_catalogue(cwd, host_id, done)
  end, function(entries, err)
    callback(entries and vim.deepcopy(entries) or nil, err)
  end)
end

---Resolve the first slash only: some model ids themselves contain slashes.
function M.find(entries, value)
  if type(value) ~= "string" then
    return nil
  end
  local provider, model_id = value:match "^([^/]+)/(.+)$"
  if not provider then
    return nil
  end
  for _, entry in ipairs(entries or {}) do
    if entry.provider == provider and entry.status == "ready" then
      for _, model in ipairs(entry.models or {}) do
        if model.id == model_id then
          return { provider = value, entry = entry, model = model }
        end
      end
    end
  end
  return nil
end

---A provider picker followed by that provider's models. An explicit value is
---validated against the same catalogue without opening either picker.
---@param opts? { cwd?: string, direct?: string, host_id?: string }
---@param callback fun(selection: table|nil, err: string|nil)
function M.select_model(opts, callback)
  opts = opts or {}
  fetch_catalogue(opts.cwd or current_root(), function(entries, err)
    if err then
      return callback(nil, err)
    end
    if opts.direct then
      local selected = M.find(entries, opts.direct)
      return callback(selected, selected and nil or "provider/model is not ready: " .. opts.direct)
    end
    local ready = vim.tbl_filter(function(entry)
      return entry.status == "ready" and #(entry.models or {}) > 0
    end, entries or {})
    if #ready == 0 then
      return callback(nil, "no provider model is ready on this daemon")
    end
    vim.schedule(function()
      require("paseo.ui.pick").select(ready, {
        kind = "paseo.provider",
        prompt = "Provider for new agents",
        format_item = function(entry)
          return ("%s  (%d models)"):format(entry.label or entry.provider, #(entry.models or {}))
        end,
      }, function(entry)
        if not entry then
          return callback(nil, nil)
        end
        require("paseo.ui.pick").select(entry.models, {
          kind = "paseo.model",
          prompt = (entry.label or entry.provider) .. " model",
          format_item = function(model)
            return ("%s%s  %s"):format(
              model.isDefault and "★ " or "  ",
              model.label or model.id,
              model.description or ""
            )
          end,
        }, function(model)
          if not model then
            return callback(nil, nil)
          end
          callback({
            provider = entry.provider .. "/" .. model.id,
            entry = entry,
            model = model,
          }, nil)
        end)
      end)
    end)
  end, opts.host_id)
end

---@deprecated  Use |paseo.ui.draft|.new. Kept because the spec drives it.
---@param selection table
---@return paseo.Draft
function M.draft(selection)
  return require("paseo.ui.draft").new(current_root(), {}, selection)
end

---The provider catalogue, as `providers` reports it.
---
---Public because the terminal presets list one entry per provider the daemon
---has, and a second copy of this call is a second thing to keep in step.
---@param cwd string
---@param callback fun(entries: table[]|nil, err: string|nil)
function M.catalogue(cwd, callback, host_id)
  fetch_catalogue(cwd, callback, host_id)
end

function M.preference(value, callback)
  M.select_model({ cwd = current_root(), direct = value }, function(selection, err)
    if selection then
      config.get().paseo.provider = selection.provider
    end
    callback(selection, err)
  end)
end

return M
