--- The agents in this workspace, live.
---
--- Fed by the push-driven directory in `paseo.agents`, so the status column is
--- current rather than polled -- which matters because a CLI call to get it
--- costs ~2.4s.
---
--- A row is a SWITCH, not a label: clicking one points this surface at that
--- agent, which is the thing the list is for. Everything else about sessions --
--- creating, archiving, searching -- still hands off to the telescope picker
--- rather than being reimplemented here.

local icons = require "paseo.ui.icons"
local agents = require "paseo.agents"
local widgets = require "paseo.ui.widgets"

local M = {}

M.title = "Sessions"

---Status glyphs, from the registry -- the timeline says the same four things
---about a tool call and used to spell them differently.
local GLYPH = {
  idle = { icons.status.idle, "PaseoDim" },
  running = { icons.status.running, "PaseoToolRunning" },
  permission = { icons.status.permission, "PaseoDanger" },
  error = { icons.status.failed, "PaseoToolFail" },
}

---@param chat table
---@param width integer
---@return table[][]
function M.lines(chat, width)
  -- The directory is push-fed. Without a subscription the panel shows an empty
  -- list and calls it "no agents here yet", which is a lie about a workspace
  -- with three running.
  agents.watch()
  local list = agents.for_root(chat.root)

  local lines = {
    { { "  Sessions in ", "PaseoHeader" }, { vim.fn.fnamemodify(chat.root, ":~"), "PaseoDim" } },
    {},
  }

  if #list == 0 then
    lines[#lines + 1] = { { "  no agents here yet", "PaseoDim" } }
    return lines
  end

  for _, agent in ipairs(list) do
    local glyph = agent.requiresAttention and GLYPH.permission
      or GLYPH[agent.status or "idle"]
      or GLYPH.idle
    local mine = agent.id == chat.agent_id
    -- Opening an EXISTING agent: the chat subscribes and fetches its timeline,
    -- so you land in the conversation as it stands rather than a blank window.
    local open = not mine
        and function()
          require("paseo.ui.chat").open {
            root = agent.cwd or chat.root,
            agent_id = agent.id,
            title = agent.title,
          }
        end
      or nil

    -- The row lights up under the pointer. Every row here was already
    -- clickable and none of them reacted to the mouse at all, which reads as
    -- "not a button" right up until you click it and the surface changes
    -- underneath you.
    local id = "sessions." .. agent.id
    local click = open and widgets.hover(id, "body", open) or nil
    local row_hl = widgets.row_hl(id, mine)

    local row = {
      { mine and "  " .. widgets.icons.mine .. " " or "    ", mine and "PaseoAgent" or nil },
      { glyph[1] .. " ", glyph[2] },
      { agent.title or agent.id, mine and "PaseoAgent" or nil },
      { agent.provider and ("   " .. agent.provider) or "", "PaseoDim" },
      { agent.requiresAttention and "   needs you" or "", "PaseoDanger" },
    }

    if row_hl then
      -- Repainted WHOLE, gaps included and per-cell colour dropped, so the
      -- highlight is one unbroken band across the full width. Keeping the
      -- status glyph's own colour would leave a hole in it, and the status is
      -- carried by the glyph's shape anyway -- idle, running, needs-you and
      -- failed are four different icons, not one icon in four colours.
      lines[#lines + 1] = widgets.fill_row(row, width, row_hl, click)
    else
      for _, cell in ipairs(row) do
        cell[3] = click
      end
      lines[#lines + 1] = row
    end
  end

  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    { "  ", "PaseoDim" },
    { ":Paseo sessions", "PaseoKey" },
    { " to switch · ", "PaseoDim" },
    { ":Paseo workspaces", "PaseoKey" },
    { " for the rest", "PaseoDim" },
  }
  return lines
end

return M
