--- Subagents: the provider's own and Paseo's, counted in the header.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_subagents()
  local bridge = require "paseo.bridge"
  local agents = require "paseo.agents"
  local subagents = require "paseo.subagents"
  local old_on, old_request = bridge.on, bridge.request

  local handlers, requests = {}, {}
  local ok, failure = pcall(function()
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

    eq("subagents: an agent with none has none", { subagents.counts "nobody" }, { 0, 0 })
    eq("subagents: a chat with no agent yet has none", #subagents.list(nil), 0)
  end)

  bridge.on, bridge.request = old_on, old_request
  agents._apply { kind = "snapshot", entries = {} }
  if not ok then
    error(failure, 0)
  end
end

return {
  { "subagents", test_subagents },
}
