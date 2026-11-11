--- Subagents: the provider's own and Paseo's, counted in the header.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_subagents()
  local bridge = require "paseo.bridge"
  local agents = require "paseo.agents"
  local subagents = require "paseo.subagents"
  local old_on, old_request = bridge.on, bridge.request
  local old_ensure, old_running = bridge.ensure, bridge.running

  local handlers, requests = {}, {}
  subagents._reset()
  local ok, failure = pcall(function()
    -- NEVER THE REAL BRIDGE. `follow` watches the agent directory, and an
    -- unstubbed `ensure` there spawned a real sidecar dialling the daemon on
    -- 6767 -- whose late answer to another suite's `agent.find` then opened a
    -- start menu in the middle of this one and hung the run on `inputlist`.
    bridge.ensure = function(callback)
      callback(nil)
    end
    -- Not running, so the rail's `track` asks nothing: what it counts here is
    -- exactly what this test pushed.
    bridge.running = function()
      return false
    end
    bridge.on = function(event, fn)
      handlers[event] = fn
    end
    bridge.request = function(op, args, callback)
      requests[#requests + 1] = op
      if op == "subagents.list" then
        -- What was already running when the chat opened: the stream only
        -- reports changes, so without this list it is never counted.
        return callback(nil, {
          subagents = {
            {
              id = "task-1",
              parentAgentId = args.agentId,
              title = "Explore",
              description = "Map the auth flow",
              status = "running",
              createdAt = "2026-10-10T10:00:00Z",
            },
          },
        })
      end
      callback(nil, {})
    end

    agents._apply {
      kind = "snapshot",
      entries = {
        {
          id = "child",
          title = "Write the migration",
          status = "running",
          createdAt = "2026-10-10T10:01:00Z",
          labels = { [subagents.PARENT_LABEL] = "parent" },
        },
        { id = "stranger", title = "unrelated", status = "running", labels = {} },
      },
    }

    subagents.follow("parent")
    vim.wait(500, function()
      return #subagents.list "parent" == 2
    end, 10)
    eq(
      "subagents: follow asks for the stream before listing",
      vim.tbl_filter(function(op)
        return op:find("^subagent") ~= nil
      end, requests),
      { "subagents.follow", "subagents.list" }
    )

    local list = subagents.list "parent"
    eq("subagents: both kinds, oldest first", vim.tbl_map(function(s)
      return s.kind .. ":" .. s.id
    end, list), { "provider:task-1", "paseo:child" })
    eq("subagents: a provider one is labelled with what it was asked", list[1].title, "Map the auth flow")
    eq("subagents: and keeps its type as the detail", list[1].detail, "Explore")
    eq("subagents: an unrelated agent is not one", #vim.tbl_filter(function(s)
      return s.id == "stranger"
    end, list), 0)

    local running, total = subagents.counts "parent"
    eq("subagents: counted", { running, total }, { 2, 2 })

    -- Pushed: one finishes, a new one starts.
    truthy("subagents: listens for the stream", handlers.subagent ~= nil)
    handlers.subagent {
      kind = "upsert",
      subagent = { id = "task-1", parentAgentId = "parent", title = "Explore", status = "completed" },
    }
    handlers.subagent {
      kind = "upsert",
      subagent = { id = "task-2", parentAgentId = "parent", title = "general-purpose", status = "running" },
    }
    vim.wait(500, function()
      return #subagents.list "parent" == 3
    end, 10)
    running, total = subagents.counts "parent"
    eq("subagents: a finished one still counts in the total", { running, total }, { 2, 3 })

    handlers.subagent { kind = "remove", parentAgentId = "parent", subagentId = "task-2" }
    vim.wait(500, function()
      return #subagents.list "parent" == 2
    end, 10)
    eq("subagents: a removed one is gone", #subagents.list "parent", 2)

    -- The header says it, and shrinks it to the numbers.
    local sidebar = require "paseo.ui.sidebar"
    local chat = { agent_id = "parent", root = "/tmp", provider = "claude" }
    local text = table.concat(vim.tbl_map(function(cell)
      return cell[1]
    end, sidebar.header(chat)))
    truthy("subagents: the header counts them", text:find("1 of 2 subagents running (gs)", 1, true) ~= nil, text)

    -- THE LIVE LIST `gs` OPENS. A picker was a snapshot: a fixed glyph for
    -- running, and no update while you read it.
    local live = require "paseo.ui.subagents"
    local icons = require "paseo.ui.icons"
    live.open(chat)
    truthy("subagents: gs opens a list", live.is_open())
    local function row_of(id)
      for line, s in pairs(live._view().rows) do
        if s.id == id then
          return line, vim.api.nvim_buf_get_lines(live._view().buf, line - 1, line, false)[1]
        end
      end
    end
    local _, child_row = row_of "child"
    truthy("subagents: a running one turns", (function()
      for _, frame in ipairs(icons.spinner) do
        if child_row:find(frame, 1, true) then
          return true
        end
      end
      return false
    end)(), child_row)
    truthy("subagents: and says so", child_row:find("running", 1, true) ~= nil, child_row)
    truthy("subagents: with a clock while it does", live._view().timer ~= nil)
    local _, done_row = row_of "task-1"
    truthy("subagents: a finished one says done", done_row:find("done", 1, true) ~= nil, done_row)
    truthy("subagents: with a still glyph", done_row:find(icons.status.completed, 1, true) ~= nil, done_row)

    -- Pushed while it is open: the row changes under you, and the cursor
    -- stays on the subagent it was on.
    local child_line = row_of "child"
    vim.api.nvim_win_set_cursor(live._view().win, { child_line, 0 })
    handlers.subagent {
      kind = "upsert",
      subagent = { id = "task-3", parentAgentId = "parent", title = "Explore", status = "running", createdAt = "2026-10-10T10:02:00Z" },
    }
    agents._apply {
      kind = "snapshot",
      entries = {
        {
          id = "child",
          title = "Write the migration",
          status = "idle",
          createdAt = "2026-10-10T10:01:00Z",
          labels = { [subagents.PARENT_LABEL] = "parent" },
        },
      },
    }
    vim.wait(500, function()
      local _, text = row_of "child"
      return text and text:find("idle", 1, true) ~= nil and (row_of "task-3") ~= nil
    end, 10)
    _, child_row = row_of "child"
    truthy("subagents: a status pushed while open is drawn", child_row:find("idle", 1, true) ~= nil, child_row)
    truthy("subagents: a new one appears", (row_of "task-3") ~= nil)
    eq("subagents: and the cursor stayed on its subagent", live.current().id, "child")
    handlers.subagent {
      kind = "upsert",
      subagent = { id = "task-3", parentAgentId = "parent", title = "Explore", status = "failed" },
    }
    vim.wait(500, function()
      return live._view().timer == nil
    end, 10)
    eq("subagents: nothing running, no clock", live._view().timer, nil)
    live.close()
    truthy("subagents: q closes it", not live.is_open())

    -- The rail's badge: the robot and the count, on the workspace the parent
    -- works in.
    local rail = require "paseo.ui.rail"
    local hosts = require "paseo.hosts"
    local ws_root = vim.fn.tempname()
    vim.fn.mkdir(ws_root, "p")
    agents._apply {
      kind = "snapshot",
      hostId = hosts.selected(),
      entries = { { id = "parent", status = "running", cwd = ws_root } },
    }
    handlers.subagent {
      kind = "upsert",
      subagent = { id = "task-4", parentAgentId = "parent", title = "Explore", status = "running" },
    }
    vim.wait(200, function()
      return rail.subagent_badge { directory = ws_root } ~= nil
        and rail.subagent_badge({ directory = ws_root })[1][1]:find("1/", 1, true) ~= nil
    end, 10)
    local badge = rail.subagent_badge { directory = ws_root }
    truthy("subagents: the rail badges a workspace with them", badge ~= nil)
    truthy("subagents: with the robot", badge[1][1]:find(icons.tool.sub_agent, 1, true) == 1, badge[1][1])
    truthy("subagents: running over total", badge[1][1]:find("1/", 1, true) ~= nil, badge[1][1])
    eq("subagents: in the running colour", badge[1][2], "PaseoToolRunning")
    eq("subagents: and nothing on a workspace without", rail.subagent_badge { directory = ws_root .. "-none" }, nil)

    eq("subagents: seconds between two stamps", subagents.seconds("2026-10-10T10:00:00Z", "2026-10-10T10:03:05Z"), 185)
    eq("subagents: a duration reads as one", subagents.duration(185), "3m 05s")
    eq("subagents: short ones in seconds", subagents.duration(42), "42s")
    eq("subagents: not a stamp is nothing", subagents.seconds "soon", nil)

    eq("subagents: an agent with none has none", { subagents.counts "nobody" }, { 0, 0 })
    eq("subagents: a chat with no agent yet has none", #subagents.list(nil), 0)
  end)

  bridge.on, bridge.request = old_on, old_request
  bridge.ensure, bridge.running = old_ensure, old_running
  subagents._reset()
  agents._apply { kind = "snapshot", entries = {} }
  if not ok then
    error(failure, 0)
  end
end

return {
  { "subagents", test_subagents },
}
