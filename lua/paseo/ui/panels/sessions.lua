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

local agents = require "paseo.agents"

local M = {}

M.title = "Sessions"

local GLYPH = {
  idle = { "●", "PaseoDim" },
  running = { "◐", "PaseoToolRunning" },
  permission = { "", "PaseoDanger" },
  error = { "✗", "PaseoToolFail" },
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
    local click = not mine
        and function()
          require("paseo.ui.chat").open {
            root = agent.cwd or chat.root,
            agent_id = agent.id,
            title = agent.title,
          }
        end
      or nil
    lines[#lines + 1] = {
      { mine and "  ▌ " or "    ", mine and "PaseoAgent" or nil, click },
      { glyph[1] .. " ", glyph[2], click },
      { agent.title or agent.id, mine and "PaseoAgent" or nil, click },
      { agent.provider and ("   " .. agent.provider) or "", "PaseoDim", click },
      { agent.requiresAttention and "   needs you" or "", "PaseoDanger", click },
    }
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
