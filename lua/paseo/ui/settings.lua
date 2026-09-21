--- The agent settings, on their own.
---
--- `:Paseo mode` used to be a `vim.ui.select` listing five strings with a `●`
--- glued to the front of one of them. This is the same four settings drawn the
--- same way the dashboard draws them -- because it IS the dashboard's view
--- object, at a different width, with its own window.
---
--- The window itself is |paseo.ui.popup|'s, which is also what the new-agent
--- screen opens. Those two used to be a volt popup and a plain buffer, and the
--- reason was only ever that the open sequence lived here.

local panel = require "paseo.ui.panels.settings"
local popup = require "paseo.ui.popup"
local render = require "paseo.ui.render"
local session = require "paseo.ui.session"
local widgets = require "paseo.ui.widgets"

local api = vim.api

local M = {}

---@type paseo.Popup|nil
local state

local XPAD = 2

---Wide enough for five permission-mode chips on one row, and never wider than
---the editor has room for.
---@return integer
local function width()
  return math.max(48, math.min(88, vim.o.columns - 8))
end

function M.close()
  local held = state
  state = nil
  if held then
    held.close()
  end
end

---@param chat table
---@param only? string  A group id -- draw just that one.
function M.open(chat, only)
  M.close()

  local view = panel.new(session.source(chat), {
    only = only,
    section = "session",
    hints = { { "q", "close" } },
    redraw = function()
      if state then
        state.rebuild()
      end
    end,
  })

  state = popup.open {
    view = view,
    width = width,
    zindex = 60,
    title = function(handle)
      local inner = handle.w - (2 * XPAD)
      local left = { { "󰒓  Agent", "PaseoHeader" } }
      local right = {}
      if chat.provider then
        right[#right + 1] = { chat.provider, "PaseoDim" }
      end
      return {
        render.truncate(widgets.row(left, right, inner, "PaseoNormal"), inner),
        { { string.rep("─", inner), "PaseoBorder" } },
        {},
      }
    end,
    on_close = function()
      state = nil
    end,
  }

  -- Fetch fresh: modes, models and thinking levels are per provider and the
  -- Paseo app may have changed one under us since the last look.
  view:reload()
end

---@return boolean
function M.is_open()
  return state ~= nil and state.win ~= nil and api.nvim_win_is_valid(state.win)
end

return M
