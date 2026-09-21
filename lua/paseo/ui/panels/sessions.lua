--- Everything running in this workspace: the agents and the terminals.
---
--- ONE LIST, because that is what Paseo has. A workspace holds agent sessions
--- and PTYs side by side, they show up in the app together, and splitting them
--- across two tabs here meant the Sessions tab was quietly a lie about what was
--- running -- it could say "no agents here yet" on a workspace with three
--- `claude` terminals in it. The kind glyph is what tells them apart.
---
--- Both halves are fed by push -- |paseo.agents| and |paseo.terminals| -- so
--- the status column is current rather than polled, which matters because a CLI
--- call to get an agent's status costs ~2.4s.
---
--- A row is an ACTION, not a label: opening one points this surface at it.
--- Everything else about sessions -- searching, archiving in bulk -- still
--- hands off to the telescope picker rather than being reimplemented here.
---
--- Drawn by |paseo.ui.list|, which owns the focus ring, `j`/`k`, `<CR>` and
--- the hint bar. This panel used to hold selection on the CURSOR through a
--- `buffer line -> item` map, which is why its keys read as broken: volt
--- resets the cursor to {1,1} after every click, nothing was ever drawn to say
--- which row you were on, and arriving at the tab never put you on one.

local agents = require "paseo.agents"
local icons = require "paseo.ui.icons"
local list = require "paseo.ui.list"
local terminals = require "paseo.terminals"
local widgets = require "paseo.ui.widgets"

local M = {}

M.title = "Sessions"

---Status glyphs, from the registry -- the timeline says the same four things
---about a tool call, and the two had spelled them differently.
local GLYPH = {
  idle = { icons.status.idle, "PaseoDim" },
  running = { icons.status.running, "PaseoToolRunning" },
  permission = { icons.status.permission, "PaseoDanger" },
  error = { icons.status.failed, "PaseoToolFail" },
}

---The KIND glyph: what tells an agent row from a terminal row.
---
---This was two literal spaces. The codepoint had been lost out of the file, so
---the one cell whose whole job is to say which of the two kinds a row is drew
---nothing at all -- and a merged list where you cannot tell the halves apart
---is the merge not having happened. See |paseo-glyphs|.
local KIND = {
  agent = { icons.panel.Sessions, "PaseoBlue1" },
  terminal = { icons.panel.Terminals, "PaseoYellow1" },
}

---The per-row key ALPHABET. Bound from this constant, never from the rows we
---happen to have: keys are taken the moment you arrive at the tab, which on a
---cold open is before the daemon has answered.
---
---Rename is `R` rather than `r`, which is what it used to be. `r` is reload on
---the Settings tab and on every list, and one key meaning "ask the daemon
---again" on five tabs and "rename this terminal" on the sixth is exactly the
---kind of near-miss that makes a surface feel like several.
local KEYS = { terminal = "c", agent = "a", rename = "R", kill = "d" }

---Start an agent in this workspace, through |paseo-new-session|.
---@param chat table
local function new_agent(chat)
  -- Through the workspace, because `agent.create` is addressed by workspace
  -- id: the directory is where the agent RUNS, not what it belongs to.
  require("paseo.workspaces").for_dir(chat.root, function(ws, err)
    vim.schedule(function()
      if not ws then
        return vim.notify("paseo: " .. tostring(err), vim.log.levels.WARN)
      end
      require("paseo.workspaces").new_session(ws, {}, function(id, create_err)
        if create_err and create_err ~= "cancelled" then
          return vim.notify("paseo: " .. create_err, vim.log.levels.ERROR)
        end
        if not id then
          return
        end
        vim.schedule(function()
          require("paseo.ui.chat").open { root = ws.directory, agent_id = id }
        end)
      end)
    end)
  end)
end

---@param id string
local function archive(id)
  -- Archiving an agent is not killing it -- the session survives on the daemon
  -- -- but it does take it off every list, so it is asked for too.
  vim.ui.select({ "no", "yes" }, { prompt = "Archive this session?" }, function(choice)
    if choice ~= "yes" then
      return
    end
    require("paseo.bridge").request("agent.archive", { agentId = id }, function(err)
      vim.schedule(function()
        vim.notify(
          err and ("paseo: " .. err) or "paseo: archived",
          err and vim.log.levels.ERROR or vim.log.levels.INFO
        )
      end)
    end)
  end)
end

---@param chat table
---@return paseo.ListSection[]
local function sections(chat)
  -- Both directories are push-fed. Without a subscription an empty table reads
  -- as "nothing here", which is a lie about a workspace with three running.
  agents.watch()
  terminals.watch(chat.root)

  local agent_rows = {}
  for _, agent in ipairs(agents.for_root(chat.root)) do
    local glyph = agent.requiresAttention and GLYPH.permission
      or GLYPH[agent.status or "idle"]
      or GLYPH.idle
    local mine = agent.id == chat.agent_id

    -- Metadata is RIGHT-ALIGNED into one column rather than trailing the
    -- title. A provider written three spaces after a title of whatever length
    -- gives a different left edge on every row, and a column you cannot scan
    -- is a column that may as well not be there.
    local right = {}
    if agent.requiresAttention then
      -- A chip, not red text. This is the one row in the list that is waiting
      -- on you, and "waiting on you" is a state, which is what a chip is for.
      right[#right + 1] = widgets.chip("needs you", "danger")
      right[#right + 1] = { " ", "PaseoDim" }
    end
    if agent.provider then
      right[#right + 1] = { agent.provider, "PaseoDim" }
    end

    agent_rows[#agent_rows + 1] = {
      id = "agent." .. agent.id,
      active = mine,
      cells = {
        { mine and "  " .. widgets.icons.mine .. " " or "    ", mine and "PaseoAgent" or nil },
        { KIND.agent[1] .. " ", KIND.agent[2] },
        { glyph[1] .. " ", glyph[2] },
        { agent.title or agent.id, mine and "PaseoAgent" or nil },
      },
      right = right,
      -- The one you are ALREADY IN is not an action. Opening any other is:
      -- the chat subscribes and fetches its timeline, so you land in the
      -- conversation as it stands rather than in a blank window.
      activate = not mine and function()
        require("paseo.ui.chat").open {
          root = agent.cwd or chat.root,
          agent_id = agent.id,
          title = agent.title,
        }
      end or nil,
      keys = {
        [KEYS.kill] = function()
          archive(agent.id)
        end,
      },
    }
  end

  local terminal_rows = {}
  for _, item in ipairs(terminals.for_root(chat.root)) do
    local glyph = terminals.glyph(item)
    local reason = item.activity and item.activity.attentionReason
    local right = {}
    if reason == "needs_input" then
      right[#right + 1] = widgets.chip("needs input", "danger")
    elseif reason == "finished" then
      right[#right + 1] = { "finished", "PaseoDim" }
    end

    terminal_rows[#terminal_rows + 1] = {
      id = "terminal." .. item.id,
      cells = {
        { "    " },
        { KIND.terminal[1] .. " ", KIND.terminal[2] },
        { glyph[1] .. " ", glyph[2] },
        { terminals.label(item), nil },
      },
      right = right,
      activate = function()
        require("paseo.ui.termfloat").open { root = chat.root, id = item.id }
      end,
      keys = {
        [KEYS.rename] = function()
          require("paseo.ui.termfloat").rename(item.id)
        end,
        [KEYS.kill] = function()
          require("paseo.ui.termfloat").kill(item.id)
        end,
      },
    }
  end

  return {
    {
      id = "agents",
      icon = icons.panel.Sessions,
      title = "Sessions in " .. vim.fn.fnamemodify(chat.root, ":~"),
      empty = terminals.ready(chat.root) and "nothing running here yet" or "loading…",
      rows = agent_rows,
    },
    {
      id = "terminals",
      icon = icons.panel.Terminals,
      hl = "PaseoYellow1",
      title = "Terminals",
      summary = { { "  " .. terminals.summary(chat.root), "PaseoDim" } },
      -- No `empty`: a workspace with agents and no terminals should not be
      -- told twice that it has nothing running.
      rows = terminal_rows,
    },
  }
end

---@param chat table
---@return paseo.ListSource
local function source(chat)
  return {
    chat = chat,
    keys = KEYS,
    hints = {
      { KEYS.terminal, "terminal" },
      { KEYS.agent, "agent" },
      { KEYS.rename, "rename" },
      { KEYS.kill, "kill" },
    },
    -- `c` and `a` MAKE a thing rather than acting on the focused row, so they
    -- belong to the list rather than to any one row of it. One key for both
    -- would have to ask which, and a list holding two kinds is exactly where
    -- that question is most annoying.
    verbs = {
      [KEYS.terminal] = function()
        local termfloat = require "paseo.ui.termfloat"
        termfloat.open { root = chat.root }
        termfloat.new()
      end,
      [KEYS.agent] = function()
        new_agent(chat)
      end,
    },
    sections = function()
      return sections(chat)
    end,
    load = function(_, done)
      terminals.watch(chat.root, function()
        vim.schedule(done)
      end)
    end,
  }
end

---@type paseo.ListView|nil
local view

---@param chat table
---@return paseo.ListView
local function view_for(chat)
  if not view or view.source.chat ~= chat then
    view = list.new(source(chat), {
      redraw = function()
        require("paseo.ui.float").rebuild()
      end,
    })
  end
  return view
end

---The view this panel is drawing, for the suite.
---
---Exposed rather than reconstructed: a test that built its own view would be
---testing |paseo.ui.list| and not this panel's wiring to it.
---@param chat table
---@return paseo.ListView
function M._view(chat)
  return view_for(chat)
end

---@param chat table
function M.load(chat)
  local v = view_for(chat)
  v.source:load(v.redraw)
end

---@param chat table
---@param width integer
---@param height? integer
---@return table[][]
function M.lines(chat, width, height)
  return view_for(chat):lines(width, height)
end

---@param chat table
---@param buf integer
function M.attach(chat, buf)
  view_for(chat):bind(buf)
end

---@param _chat table
---@param buf integer
function M.detach(_chat, buf)
  if view then
    view:unbind(buf)
  end
end

return M
