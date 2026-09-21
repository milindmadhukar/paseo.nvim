--- Provider selection and the settings review shown before a new agent exists.
--- The daemon supplies every choice. This module owns no persistent preference:
--- :Paseo model stores one in config for the current Neovim process.

local bridge = require "paseo.bridge"
local config = require "paseo.config"

local M = {}

local function current_root()
  local chat = require("paseo.ui.chat").current()
  return chat and chat.root or assert(vim.uv.cwd())
end

local function fetch_catalogue(cwd, callback)
  bridge.ensure(function(err)
    if err then
      return callback(nil, err)
    end
    bridge.request("providers", { cwd = cwd }, function(fetch_err, result)
      callback(result and result.entries or nil, fetch_err)
    end)
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
---@param opts? { cwd?: string, direct?: string }
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
      vim.ui.select(ready, {
        prompt = "Provider for new agents",
        format_item = function(entry)
          return ("%s  (%d models)"):format(entry.label or entry.provider, #(entry.models or {}))
        end,
      }, function(entry)
        if not entry then
          return callback(nil, nil)
        end
        vim.ui.select(entry.models, {
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
  end)
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
function M.catalogue(cwd, callback)
  fetch_catalogue(cwd, callback)
end

---Everything a new agent session is set to, before it exists, on one screen.
---
---This used to be a plain buffer -- `("%-15s %s"):format(label, value)`, no
---highlights, a `vim.ui.select` for every choice -- while the Agent tab drew
---the same settings as cards. It is now the SAME VIEW as that tab, over a
---draft instead of a running agent, so the screen you set an agent up on and
---the screen you change it on are one renderer.
---
---Which also retires the picker: a cold open lands on the Provider card with
---the first ready provider selected, rather than opening two `vim.ui.select`
---prompts before you see anything. The screen IS the picker.
---@param opts { cwd: string, preferred?: string }
---@param callback fun(draft: table|nil, err: string|nil)
function M.review(opts, callback)
  local draft_model = require "paseo.ui.draft"
  local panel = require "paseo.ui.panels.settings"
  local popup = require "paseo.ui.popup"
  local render = require "paseo.ui.render"
  local widgets = require "paseo.ui.widgets"

  local handle
  local done = false

  ---Exactly once, whatever got us here: `q`, `<Esc>`, `c`, a `WinClosed`, or
  ---a failure before there was ever a window. volt's own `q` routes through
  ---`after_close`, which is `handle.close`, which is `on_close`, which is
  ---this -- so the cancel path and the create path meet in one place.
  local function finish(result, err)
    if done then
      return
    end
    done = true
    if handle then
      handle.close()
    end
    callback(result, err)
  end

  fetch_catalogue(opts.cwd, function(entries, err)
    if err then
      return finish(nil, err)
    end

    local selection = M.find(entries, opts.preferred) or draft_model.first(entries)
    if not selection then
      -- No window for this. There is nothing on the screen to choose between.
      return finish(nil, "no provider on this daemon has a model ready")
    end

    vim.schedule(function()
      if done then
        return
      end
      local draft = draft_model.new(opts.cwd, entries, selection)

      local function create()
        -- The features are part of what is being created, so creating before
        -- they land would create something other than what the screen says.
        if draft.loading then
          return
        end
        finish(draft_model.result(draft), nil)
      end

      local view = panel.new(draft_model.source(draft), {
        section = "session",
        hints = { { "c", "create" }, { "q", "cancel" } },
        redraw = function()
          if handle then
            handle.rebuild()
          end
        end,
      })

      -- `create` is not a settings group -- a card that is not a setting reads
      -- as one -- so it is a row of its own under the cards, clickable the way
      -- `widgets.radio` is clickable: the action on every cell, so the target
      -- is the row and not the two words on it.
      view.footer = function(w)
        local label = draft.loading and "waiting for this model's features…" or "create agent"
        local line = widgets.row(
          { widgets.keycap "c", { "  " .. label, draft.loading and "PaseoDim" or nil } },
          { { draft.provider, "PaseoDim" } },
          w
        )
        for _, cell in ipairs(line) do
          cell[3] = cell[3] or create
        end
        return { line, {} }
      end

      handle = popup.open {
        view = view,
        width = function()
          return math.max(52, math.min(92, vim.o.columns - 8))
        end,
        zindex = 60,
        filetype = "paseo-create",
        title = function(h)
          local inner = h.w - 4
          return {
            render.truncate(
              widgets.row(
                { { "  New agent", "PaseoHeader" } },
                { { vim.fn.fnamemodify(opts.cwd, ":~"), "PaseoDim" } },
                inner,
                "PaseoNormal"
              ),
              inner
            ),
            { { string.rep("─", inner), "PaseoBorder" } },
            {},
          }
        end,
        keys = {
          { "c", create, "paseo: create this agent session" },
        },
        -- volt owns `q` and `<Esc>`; both land here.
        on_close = function()
          finish(nil, nil)
        end,
      }

      -- Opened first, then asked: the screen appears in its loading state
      -- rather than after a round trip.
      draft_model.refresh_features(draft, false, function()
        if handle and not done then
          handle.rebuild()
        end
      end)
    end)
  end)
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
