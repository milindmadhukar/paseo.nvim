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
--- A row is an ACTION, not a label: an agent row points this surface at that
--- agent, a terminal row opens |paseo.ui.termfloat| on it. Everything else
--- about sessions -- searching, archiving in bulk -- still hands off to the
--- telescope picker rather than being reimplemented here.

local agents = require "paseo.agents"
local icons = require "paseo.ui.icons"
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
  agent = { icons.panel.Sessions, "PaseoBlue2" },
  terminal = { icons.panel.Terminals, "PaseoYellow2" },
}

---One list row, painted whole when it is hovered or current.
---
---`fill_row` drops per-cell colour so the highlight is one unbroken band
---across the full width rather than stopping where the text does. The status
---is carried by the glyph's SHAPE anyway -- idle, running, needs-you and
---failed are four different icons, not one icon in four colours.
---@param cells table[]
---@param id string
---@param width integer
---@param click function|nil
---@param current boolean|nil
---@return table[]
local function row(cells, id, width, click, current)
  local action = click and widgets.hover(id, "body", click) or nil
  local hl = widgets.row_hl(id, current)

  if hl then
    return widgets.fill_row(cells, width, hl, action)
  end
  for _, cell in ipairs(cells) do
    cell[3] = action
  end
  return cells
end

---Buffer line -> what is on it, rebuilt on every draw.
---
---Deliberately a map rather than arithmetic on the cursor row. The panel this
---absorbed computed `row - 5` from the number of heading rows it happened to
---have, so adding a line to the heading silently retargeted `d`.
---@type table<integer, { kind: "agent"|"terminal", id: string, root: string|nil }>
M._rows = {}

---@return integer  The buffer line the panel's first line is drawn on.
local function offset()
  return require("paseo.ui.float").body_row_offset()
end

---@param chat table
---@param width integer
---@return table[][]
function M.lines(chat, width)
  -- Both directories are push-fed. Without a subscription an empty table reads
  -- as "nothing here", which is a lie about a workspace with three running.
  agents.watch()
  terminals.watch(chat.root)

  local agent_list = agents.for_root(chat.root)
  local terminal_list = terminals.for_root(chat.root)
  M._rows = {}

  local lines = {
    {
      { "  " .. icons.panel.Sessions .. "  ", "PaseoBlue1" },
      { "Sessions in ", "PaseoHeader" },
      { vim.fn.fnamemodify(chat.root, ":~"), "PaseoDim" },
    },
    {},
  }

  ---Record which entity the line just appended belongs to.
  local function claim(kind, id, root)
    M._rows[#lines + offset()] = { kind = kind, id = id, root = root }
  end

  if #agent_list == 0 and #terminal_list == 0 then
    lines[#lines + 1] = {
      { "  ", "PaseoDim" },
      {
        terminals.ready(chat.root) and "nothing running here yet" or "loading…",
        "PaseoDim",
      },
    }
  end

  for _, agent in ipairs(agent_list) do
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
    lines[#lines + 1] = row({
      { mine and "  " .. widgets.icons.mine .. " " or "    ", mine and "PaseoAgent" or nil },
      { KIND.agent[1] .. " ", KIND.agent[2] },
      { glyph[1] .. " ", glyph[2] },
      { agent.title or agent.id, mine and "PaseoAgent" or nil },
      { agent.provider and ("   " .. agent.provider) or "", "PaseoDim" },
      { agent.requiresAttention and "   needs you" or "", "PaseoDanger" },
    }, "sessions.agent." .. agent.id, width, click, mine)
    claim("agent", agent.id, agent.cwd or chat.root)
  end

  if #terminal_list > 0 then
    if #agent_list > 0 then
      lines[#lines + 1] = {}
    end
    lines[#lines + 1] = {
      { "  " .. icons.panel.Terminals .. "  ", "PaseoYellow1" },
      { "Terminals", "PaseoHeader" },
      { "  " .. terminals.summary(chat.root), "PaseoDim" },
    }
    lines[#lines + 1] = {}
  end

  for _, item in ipairs(terminal_list) do
    local glyph = terminals.glyph(item)
    local click = function()
      require("paseo.ui.termfloat").open { root = chat.root, id = item.id }
    end
    local reason = item.activity and item.activity.attentionReason
    lines[#lines + 1] = row({
      { "    " },
      { KIND.terminal[1] .. " ", KIND.terminal[2] },
      { glyph[1] .. " ", glyph[2] },
      { terminals.label(item), nil },
      { reason == "needs_input" and "   needs input" or "", "PaseoDanger" },
      { reason == "finished" and "   finished" or "", "PaseoDim" },
    }, "sessions.terminal." .. item.id, width, click)
    claim("terminal", item.id, chat.root)
  end

  lines[#lines + 1] = {}
  lines[#lines + 1] = widgets.hints {
    { "<CR>", "open" },
    { "c", "terminal" },
    { "a", "agent" },
    { "r", "rename" },
    { "d", "kill" },
  }
  return lines
end

---What the cursor is on.
---@return table|nil
local function under_cursor()
  local win = vim.api.nvim_get_current_win()
  return M._rows[vim.api.nvim_win_get_cursor(win)[1]]
end

---What this panel has bound on the shared chrome buffer.
---@type table[]|nil
local bound

---@param chat table
---@param buf integer
function M.attach(chat, buf)
  local function row_kind(kind)
    local row = under_cursor()
    return row and row.kind == kind and row or nil
  end

  -- Through |paseo.ui.keys|, which gives back what it displaced. The six
  -- panels share one chrome buffer and volt binds `<CR>` on it at open, so a
  -- panel that merely DELETED its own `<CR>` would leave the key dead on all
  -- five of the others.
  bound = require("paseo.ui.keys").take(buf, {
    {
      "<CR>",
      function()
        local row = under_cursor()
        if not row then
          return
        end
        if row.kind == "terminal" then
          return require("paseo.ui.termfloat").open { root = chat.root, id = row.id }
        end
        if row.id ~= chat.agent_id then
          require("paseo.ui.chat").open { root = row.root, agent_id = row.id }
        end
      end,
      "paseo: open this session",
    },
    -- `c` makes a terminal and `a` makes an agent. One key for both would have
    -- to ask which, and a list holding two kinds is exactly where that
    -- question is most annoying.
    {
      "c",
      function()
        local termfloat = require "paseo.ui.termfloat"
        termfloat.open { root = chat.root }
        termfloat.new()
      end,
      "paseo: new terminal",
    },
    {
      "a",
      function()
        -- Through the workspace, because `agent.create` is addressed by
        -- workspace id: the directory is where the agent RUNS, not what it
        -- belongs to.
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
      end,
      "paseo: new agent",
    },
    {
      "r",
      function()
        local row = row_kind "terminal"
        if row then
          require("paseo.ui.termfloat").rename(row.id)
        end
      end,
      "paseo: rename this terminal",
    },
    {
      "d",
      function()
        local row = under_cursor()
        if not row then
          return
        end
        if row.kind == "terminal" then
          return require("paseo.ui.termfloat").kill(row.id)
        end
        -- Archiving an agent is not killing it -- the session survives on the
        -- daemon -- but it does take it off every list, so it is asked for too.
        vim.ui.select({ "no", "yes" }, { prompt = "Archive this session?" }, function(choice)
          if choice ~= "yes" then
            return
          end
          require("paseo.bridge").request("agent.archive", { agentId = row.id }, function(err)
            vim.schedule(function()
              vim.notify(
                err and ("paseo: " .. err) or "paseo: archived",
                err and vim.log.levels.ERROR or vim.log.levels.INFO
              )
            end)
          end)
        end)
      end,
      "paseo: kill or archive this session",
    },
  })
end

---@param _chat table
---@param buf integer
function M.detach(_chat, buf)
  local saved = bound
  bound = nil
  require("paseo.ui.keys").release(buf, saved)
end

---@param chat table
function M.load(chat)
  terminals.watch(chat.root, function()
    vim.schedule(function()
      require("paseo.ui.float").rebuild()
    end)
  end)
end

return M
