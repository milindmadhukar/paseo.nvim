--- The search: one list of workspaces, agents, prompts and past chats.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function kinds(rows)
  local out = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row.kind .. ":" .. row.title
  end
  return out
end

--- Rows, in the order an empty query shows them.
local function test_rows()
  local search = require "paseo.pickers.search"
  local rows = search.rows {
    bucket = function(agent)
      return agent.bucket
    end,
    ws_bucket = function()
      return "done"
    end,
    workspaces = {
      { id = "w1", hostId = "h", title = "Search work", name = "search", project = "paseo.nvim", branch = "feat/search" },
    },
    agents = {
      { id = "a-done", hostId = "h", title = "Done one", bucket = "done", workspaceId = "w1", createdAt = "2" },
      { id = "a-wait", hostId = "h", title = "Waiting one", bucket = "needs_input", createdAt = "1" },
      { id = "a-new", hostId = "h", title = "Newer done", bucket = "done", createdAt = "3" },
      -- A subagent is a peek, never a row of its own.
      { id = "a-sub", hostId = "h", title = "Sub", bucket = "running", labels = { ["paseo.parent-agent-id"] = "a-done" } },
    },
    prompts = {
      ["h:a-done"] = {
        agent = { id = "a-done", hostId = "h", title = "Done one", workspaceId = "w1" },
        epoch = "e1",
        prompts = {
          { seq = 3, timestamp = "2026-01-01T00:00:00Z", preview = "fix the\nrail" },
          { seq = 9, timestamp = "2026-01-02T00:00:00Z", preview = "now the search" },
          { seq = 11, timestamp = "2026-01-03T00:00:00Z", preview = "   " },
        },
      },
    },
    archived = {
      { id = "old", hostId = "h", title = "Old chat", workspaceName = "gone", branch = "main", projectName = "app" },
    },
  }

  eq("rows: urgent agents first, then newest, then workspaces, prompts, past chats", kinds(rows), {
    "agent:Waiting one",
    "agent:Newer done",
    "agent:Done one",
    "workspace:Search work",
    "prompt:now the search",
    "prompt:fix the rail",
    "archived:Old chat",
  })

  local done = rows[3]
  eq("rows: an agent says where it lives", done.detail, "Search work · feat/search")
  truthy("rows: and matches on its workspace's branch", done.ordinal:find("feat/search", 1, true))

  local prompt = rows[5]
  eq("rows: a prompt carries its seq and epoch", { prompt.seq, prompt.epoch }, { 9, "e1" })
  eq("rows: and names the chat it was sent to", prompt.detail, "Done one")
  truthy("rows: which it also matches on", prompt.ordinal:find("Done one", 1, true))
  eq("rows: a prompt's paragraph is one line", rows[6].title, "fix the rail")

  eq("rows: a workspace named for its branch says it once", search.rows({
    workspaces = { { id = "w", hostId = "h", title = "main", branch = "main" } },
    agents = { { id = "x", hostId = "h", title = "X", workspaceId = "w", provider = "fake" } },
    bucket = function()
      return "done"
    end,
    ws_bucket = function()
      return "done"
    end,
  })[1].detail, "main · fake")

  local old = rows[7]
  eq("rows: a past chat matches its workspace, branch and project", old.ordinal, "Old chat gone main app")

  local keys = {}
  for _, row in ipairs(rows) do
    truthy("rows: every key is unique (" .. row.key .. ")", not keys[row.key])
    keys[row.key] = true
  end
end

--- Gathering: everything at once, one answer, kept for the next open.
local function test_gather()
  local search = require "paseo.pickers.search"
  local bridge = require "paseo.bridge"
  local store = require "paseo.store"
  local hosts = require "paseo.hosts"
  local old_request, old_all = bridge.request, hosts.all

  local asked = {}
  local ok, err = pcall(function()
    store.invalidate "search."
    hosts.all = function()
      return { { id = "h" } }
    end
    bridge.request = function(op, args, callback)
      asked[#asked + 1] = op .. ":" .. tostring(args.agentId)
      if op == "timeline.prompts" then
        if args.agentId == "broken" then
          return callback("no such agent")
        end
        return callback(nil, { epoch = "e", prompts = { { seq = 1, preview = "hi " .. args.agentId } } })
      end
      if op == "agents.history" then
        return callback(nil, { entries = { { id = "old", title = "Old" } } })
      end
      callback(nil, {})
    end

    local live = {
      { id = "a1", hostId = "h" },
      { id = "broken", hostId = "h" },
      { id = "sub", hostId = "h", labels = { ["paseo.parent-agent-id"] = "a1" } },
    }
    local calls, prompts, archived = 0, nil, nil
    search.gather(live, function(p, a)
      calls, prompts, archived = calls + 1, p, a
    end)
    eq("gather: answers once", calls, 1)
    truthy("gather: with the prompts of every live agent", prompts["h:a1"] ~= nil)
    eq("gather: a failed one is just missing", prompts["h:broken"], nil)
    eq("gather: and the archived agents, with their host", { archived[1].id, archived[1].hostId }, { "old", "h" })
    eq("gather: never a subagent's prompts", vim.tbl_contains(asked, "timeline.prompts:sub"), false)

    asked = {}
    search.gather(live, function() end)
    eq("gather: the next open asks again only for what failed", asked, { "timeline.prompts:broken" })
  end)

  bridge.request, hosts.all = old_request, old_all
  store.invalidate "search."
  if not ok then
    error(err)
  end
end

--- Preview: a header, then the chat as cards.
local function test_preview()
  local search = require "paseo.pickers.search"
  local row = { kind = "agent", title = "Chat", detail = "ws · main", agent = { status = "idle" } }
  local function text(lines)
    local out = {}
    for _, line in ipairs(lines) do
      local parts = {}
      for _, cell in ipairs(line) do
        parts[#parts + 1] = cell[1]
      end
      out[#out + 1] = table.concat(parts)
    end
    return table.concat(out, "\n")
  end
  truthy("preview: says it is loading", text(search.preview_lines(row, nil, 60)):find("loading", 1, true))
  truthy("preview: says why it failed", text(search.preview_lines(row, nil, 60, "boom")):find("boom", 1, true))
  local drawn = text(search.preview_lines(row, {
    { kind = "user", text = "what is the rail" },
    { kind = "text", text = "the column on the left" },
  }, 60))
  truthy("preview: the header names it", drawn:find("Chat", 1, true))
  truthy("preview: the prompt is drawn", drawn:find("what is the rail", 1, true))
  truthy("preview: and the reply", drawn:find("the column on the left", 1, true))
end

--- Picking: a prompt opens its chat AT that message.
local function test_pick()
  local search = require "paseo.pickers.search"
  local chat = require "paseo.ui.chat"
  local native = require "paseo.ui.native"
  local old_open, old_on_tab, old_show = chat.open, native.on_tab, native.show_session

  local ok, err = pcall(function()
    local opened, shown
    chat.open = function(opts)
      opened = opts
    end
    native.show_session = function(session)
      shown = session
    end
    native.on_tab = function()
      return false
    end
    local row = {
      kind = "prompt",
      host_id = "h",
      seq = 42,
      agent = { id = "a1", cwd = "/w", title = "Chat" },
    }
    search.pick(row)
    eq("pick: a prompt opens its chat", { opened.agent_id, opened.root, opened.remote }, { "a1", "/w", true })
    eq("pick: at the message", opened.at, 42)

    native.on_tab = function()
      return true
    end
    search.pick(row)
    eq("pick: on the Paseo tab, as one of its sessions", { shown.id, shown.at, shown.cwd }, { "a1", 42, "/w" })

    opened = nil
    search.pick { kind = "archived", host_id = "h", agent = { id = "old", cwd = "/o", title = "Old" } }
    eq("pick: a past chat carries what the directory does not have", { shown.id, shown.cwd, shown.title }, { "old", "/o", "Old" })
  end)

  chat.open, native.on_tab, native.show_session = old_open, old_on_tab, old_show
  if not ok then
    error(err)
  end
end

--- Without telescope: every row, in the plugin's own chooser.
local function test_fallback()
  local search = require "paseo.pickers.search"
  local choose = require "paseo.ui.choose"
  local agents = require "paseo.agents"
  local workspaces = require "paseo.workspaces"
  local old = {
    has = search.has_telescope,
    open = choose.open,
    watch = agents.watch_all,
    all = agents.all,
    list = workspaces.list_all,
    gather = search.gather,
  }

  local ok, err = pcall(function()
    local got, updated
    search.has_telescope = function()
      return false
    end
    agents.watch_all = function(cb)
      cb(nil)
    end
    agents.all = function()
      return { { id = "a1", hostId = "h", title = "Live" } }
    end
    workspaces.list_all = function(cb)
      cb { { id = "w1", hostId = "h", title = "WS" } }
    end
    search.gather = function(_, done)
      done({ ["h:a1"] = { agent = { id = "a1", hostId = "h", title = "Live" }, prompts = { { seq = 1, preview = "hello" } } } }, {})
    end
    choose.open = function(opts)
      got = opts
      return {
        closed = false,
        update = function(items)
          updated = items
        end,
      }
    end
    search.open()
    truthy(
      "fallback: the chooser opens",
      vim.wait(1000, function()
        return got ~= nil and updated ~= nil
      end)
    )
    eq("fallback: on what is live", #got.items, 2)
    eq("fallback: then every prompt too", #updated, 3)
  end)

  search.has_telescope = old.has
  choose.open = old.open
  agents.watch_all, agents.all = old.watch, old.all
  workspaces.list_all = old.list
  search.gather = old.gather
  if not ok then
    error(err)
  end
end

--- The keys: unbound on the surface and in a terminal (`<C-k>` is window-up
--- in most configs), `prev` too; the search is a global key of your own.
local function test_keys()
  local config = require "paseo.config"
  config.setup {}
  local ui = config.get().ui
  eq("keys: the surface does not take <C-k>", ui.native.keys.search, false)
  eq("keys: nor does a terminal", ui.terminal.keys.search, false)
  eq("keys: whose prev is unbound now", ui.terminal.keys.prev, false)
  eq("keys: and there is an API for your own", type(require("paseo").search), "function")
end

return {
  { "search rows", test_rows },
  { "search gather", test_gather },
  { "search preview", test_preview },
  { "search pick", test_pick },
  { "search fallback", test_fallback },
  { "search keys", test_keys },
}
