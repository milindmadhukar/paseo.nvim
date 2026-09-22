--- Everything running in this workspace: the agents and the terminals.
---
--- ONE LIST, because that is what Paseo has. A workspace holds agent sessions
--- and PTYs side by side, they show up in the app together, and splitting them
--- across two tabs here meant the Sessions tab was quietly a lie about what was
--- running -- it could say "no agents here yet" on a workspace with three
--- `claude` terminals in it. The kind glyph is what tells them apart.
---
--- THE NAVIGATION, not a readout of it. There used to be a strip of session
--- chips under the tab bar doing the same job in a worse shape: a second row
--- of things to click, directly under the first, which could not hold more
--- than about four names before it started dropping them for a `+3`. Moving
--- between sessions happens here, where there is room for every session, a
--- status column, and a search over the lot -- `/`, fuzzy, against the titles.
---
--- Both halves are fed by push -- |paseo.agents| and |paseo.terminals| -- so
--- the status column is current rather than polled, which matters because a CLI
--- call to get an agent's status costs ~2.4s.
---
--- A row is an ACTION, not a label: opening one points this surface at it.
--- Archiving in bulk still hands off to the telescope picker rather than being
--- reimplemented here.
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
---
---`/` is NOT in here: search belongs to |paseo.ui.list|, which owns the focus
---model the filter has to keep in step with.
local KEYS = { terminal = "c", agent = "a", copy = "y", rename = "R", kill = "d" }

---Which session the dashboard is showing right now.
---
---THE FLOAT'S ANSWER, not `chat.agent_id`. They are the same thing right up
---until the Chat tab is pointed at a terminal, and then they are not: the
---agent row went on drawing itself as the one you were in -- and, because the
---one you are in is not an action, went on refusing to open. That is the
---"cannot get back to my agent from the session list" bug, and it was a row
---that had no `activate` rather than a key that did not fire.
---@param chat table
---@return { kind: string, id: string|nil }
local function here(chat)
  return require("paseo.ui.float").session() or { kind = "agent", id = chat.agent_id }
end

---Start an agent, here or in a workspace of its own.
---
---ASKS WHERE, which it never used to. `a` on this panel could only ever put
---an agent in the workspace you were already standing in -- which is the
---right default and the wrong only option, because two agents in one
---directory edit the same files, and "give this one a worktree of its own"
---was reachable only from the Workspaces tab by creating the workspace first
---and then finding your way back. See |paseo.start|.
---@param chat table
local function new_agent(chat)
  -- Through the workspace, because `agent.create` is addressed by workspace
  -- id: the directory is where the agent RUNS, not what it belongs to.
  require("paseo.workspaces").for_dir(chat.root, function(ws, err)
    vim.schedule(function()
      if not ws then
        return vim.notify("paseo: " .. tostring(err), vim.log.levels.WARN)
      end
      require("paseo.start").agent({ root = chat.root, workspace = ws }, function(_, start_err)
        if start_err then
          vim.notify("paseo: " .. start_err, vim.log.levels.ERROR)
        end
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

  local at = here(chat)
  local agent_rows = {}
  for _, agent in ipairs(agents.for_root(chat.root)) do
    local glyph = agent.requiresAttention and GLYPH.permission
      or GLYPH[agent.status or "idle"]
      or GLYPH.idle
    -- `mine` is "the session on screen RIGHT NOW", which while the Chat tab is
    -- showing a terminal is none of these rows -- see `here`.
    local mine = at.kind == "agent" and at.id == agent.id

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
      -- No leading indent and no "this one is mine" marker: |paseo.ui.list|
      -- draws both, in a gutter the focus band cannot paint over. Writing it
      -- into the row is what made the active session invisible the moment you
      -- pointed at it.
      cells = {
        { KIND.agent[1] .. " ", KIND.agent[2] },
        { glyph[1] .. " ", glyph[2] },
        { agent.title or agent.id, mine and "PaseoAgent" or nil },
      },
      right = right,
      -- Matched on the TITLE and the provider, not on the drawn row: the cells
      -- lead with two glyphs, and a search for `c` that ranked every row by
      -- how well it matched a console icon would be worse than no search.
      text = (agent.title or agent.id) .. " " .. (agent.provider or ""),
      -- The one you are ALREADY IN is not an action. Opening any other is --
      -- INCLUDING this chat's own agent when the Chat tab is pointed at a
      -- terminal, which is the way back to the conversation and was the one
      -- row in the list that did nothing.
      activate = not mine and function()
        if agent.id == chat.agent_id then
          -- Ours already: a repaint, not a new chat. `chat.open` would
          -- subscribe and re-fetch a timeline we are holding.
          return require("paseo.ui.float").show_session { kind = "agent", id = agent.id }
        end
        require("paseo.ui.chat").open {
          root = agent.cwd or chat.root,
          agent_id = agent.id,
          title = agent.title,
        }
      end or nil,
      keys = {
        [KEYS.copy] = function()
          agents.copy_id { id = agent.id, title = agent.title }
        end,
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
      active = at.kind == "terminal" and at.id == item.id,
      cells = {
        { KIND.terminal[1] .. " ", KIND.terminal[2] },
        { glyph[1] .. " ", glyph[2] },
        { terminals.label(item), nil },
      },
      right = right,
      text = terminals.label(item),
      -- A terminal is a SESSION: opening one points the Chat tab at it, the
      -- same way opening an agent does. It used to open a surface of its own,
      -- over the top of this one.
      activate = function()
        require("paseo.ui.float").show_session { kind = "terminal", id = item.id }
      end,
      keys = {
        [KEYS.rename] = function()
          terminals.rename(item.id)
        end,
        [KEYS.kill] = function()
          terminals.kill(item.id)
        end,
      },
    }
  end

  return {
    {
      id = "agents",
      icon = icons.panel.Sessions,
      -- "Agents", not "Sessions": the TAB is Sessions, and both blocks under
      -- it are sessions. A heading repeating the tab's name over half of what
      -- the tab holds is the row that made the old split read as a lie.
      title = "Agents in " .. vim.fn.fnamemodify(chat.root, ":~"),
      -- NAMES THE TWO KEYS. This is the one row on the surface someone with
      -- an empty workspace will be looking at, and "nothing running here yet"
      -- on its own is a dead end -- the hint bar carries `a` and `c` but it
      -- is at the other end of the screen from the sentence saying there is
      -- nothing here.
      empty = terminals.ready(chat.root)
          and ("nothing running here yet — %s for an agent, %s for a terminal"):format(
            KEYS.agent,
            KEYS.terminal
          )
        or "loading…",
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
    -- FUZZY, over the titles, through |paseo.ui.list|. This is the list that
    -- most needs it: one workspace routinely holds a dozen sessions with names
    -- that share a prefix, and the strip it replaces could show about four.
    search = "sessions",
    anchor = function()
      return require("paseo.ui.float").body_area()
    end,
    hints = {
      { KEYS.terminal, "terminal" },
      { KEYS.agent, "agent" },
      { KEYS.copy, "agent ID" },
      { KEYS.rename, "rename" },
      { KEYS.kill, "kill" },
    },
    -- `c` and `a` MAKE a thing rather than acting on the focused row, so they
    -- belong to the list rather than to any one row of it. One key for both
    -- would have to ask which, and a list holding two kinds is exactly where
    -- that question is most annoying.
    verbs = {
      [KEYS.terminal] = function()
        local float = require "paseo.ui.float"
        local size = float.body_size()
        require("paseo.ui.newterm").open({ root = chat.root, size = size }, function(id)
          if id then
            float.show_session { kind = "terminal", id = id }
          end
        end)
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
    -- The search goes with the visit. Coming back to a tab still narrowed by a
    -- word typed ten minutes ago reads as sessions having vanished.
    view:reset()
  end
end

return M
