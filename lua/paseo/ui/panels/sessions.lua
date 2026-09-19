--- The agents in this workspace, live.
---
--- Fed by the push-driven directory in `paseo.agents`, so the status column is
--- current rather than polled -- which matters because a CLI call to get it
--- costs ~2.4s.
---
--- Read-only on purpose: `<CR>` hands off to the existing telescope picker
--- rather than reimplementing three hundred lines of it here.

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
    lines[#lines + 1] = {
      { mine and "  ▌ " or "    ", mine and "PaseoAgent" or nil },
      { glyph[1] .. " ", glyph[2] },
      { agent.title or agent.id, mine and "PaseoAgent" or nil },
      { agent.provider and ("   " .. agent.provider) or "", "PaseoDim" },
      { agent.requiresAttention and "   needs you" or "", "PaseoDanger" },
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
