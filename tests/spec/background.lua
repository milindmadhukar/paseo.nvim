--- Background work: what an agent left running, counted on the rail and the
--- bar, listed by `gb`, stopped with `x`.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local function test_background()
  local bridge = require "paseo.bridge"
  local agents = require "paseo.agents"
  local hosts = require "paseo.hosts"
  local background = require "paseo.background"
  local rail = require "paseo.ui.rail"
  local old_on, old_request = bridge.on, bridge.request
  local old_ensure, old_running = bridge.ensure, bridge.running

  local handlers, requests = {}, {}
  local stop_reply = nil
  background._reset()
  local ok, failure = pcall(function()
    -- Never the real bridge: see the subagents suite.
    bridge.ensure = function(callback)
      callback(nil)
    end
    bridge.running = function()
      return false
    end
    bridge.on = function(event, fn)
      handlers[event] = fn
    end
    bridge.request = function(op, args, callback)
      requests[#requests + 1] = { op = op, args = args }
      if op == "background.follow" then
        return callback(nil, { following = true, supported = true })
      end
      if op == "background.list" then
        -- What was already running when the chat opened.
        return callback(nil, {
          agentId = args.agentId,
          supported = true,
          items = {
            {
              id = "bash_1",
              kind = "shell",
              description = "Run dev server",
              command = "npm run dev",
              startedAt = "2026-11-25T10:00:00.000Z",
              canStop = true,
              stopToken = "tok-shell",
            },
            {
              id = "heartbeat:s1",
              kind = "heartbeat",
              description = "nightly check",
              startedAt = "2026-11-20T10:00:00.000Z",
              canStop = true,
              stopToken = "tok-hb",
            },
          },
        })
      end
      if op == "background.stop" then
        return callback(stop_reply, stop_reply == nil and { stopped = true } or nil)
      end
      callback(nil, {})
    end

    -- THE GREEN DOT OVER A RUNNING DEV SERVER. The agent's turn is over and
    -- what it started is still going: running, as the app has it.
    local ws_root = vim.fn.tempname()
    agents._apply {
      kind = "snapshot",
      hostId = hosts.selected(),
      entries = {
        { id = "a1", status = "idle", cwd = ws_root, backgroundWork = { count = 2, running = 1 } },
      },
    }
    eq("background: an idle agent with running work runs", agents.bucket(agents.get "a1"), "running")
    eq("background: and so does its workspace", agents.workspace_bucket(ws_root), "running")
    -- A heartbeat is counted and does not run.
    eq(
      "background: a heartbeat alone does not make it run",
      agents.bucket { status = "idle", backgroundWork = { count = 1, running = 0 } },
      "done"
    )
    eq("background: nor does none", agents.bucket { status = "idle" }, "done")
    eq(
      "background: a permission still outranks it",
      agents.bucket { status = "idle", pendingPermissionCount = 1, backgroundWork = { count = 1, running = 1 } },
      "needs_input"
    )

    local badge = rail.background_badge(agents.get "a1")
    eq("background: the rail row counts it", badge[1][1], "  &2")
    eq("background: in the running colour while any runs", badge[1][2], "PaseoTreeRunning")
    eq(
      "background: dim when only a heartbeat waits",
      rail.background_badge({ backgroundWork = { count = 1, running = 0 } })[1][2],
      "PaseoTreeMeta"
    )
    eq("background: and nothing without", rail.background_badge { status = "idle" }, nil)

    -- The list: asked for on follow, then replaced whole by every update.
    background.follow("a1", hosts.selected())
    vim.wait(200, function()
      return background.known("a1", hosts.selected())
    end, 10)
    local list = background.list("a1", hosts.selected())
    eq("background: follow lists what was already running", #list, 2)
    eq("background: running over total from the list", { background.counts("a1", hosts.selected()) }, { 1, 2 })
    eq("background: a title is the description", background.text(list[1]), "Run dev server")
    eq("background: the command under it", select(2, background.text(list[1])), "npm run dev")
    eq(
      "background: no command line when it IS the title",
      select(2, background.text { kind = "shell", command = "sleep 600" }),
      nil
    )
    eq("background: and the kind when there is nothing else", background.text { kind = "monitor" }, "monitor")

    local hint = require("paseo.ui.composer").background_hint {
      agent_id = "a1",
      host_id = hosts.selected(),
    }
    eq("background: the bar counts it", hint[1][1], " 2 background ")
    eq("background: with the key that lists it", hint[2][1], "gb")
    eq("background: a chat with none says nothing", #require("paseo.ui.composer").background_hint { agent_id = "zz" }, 0)

    -- Stopping: pending until the item leaves the list.
    background.stop("a1", hosts.selected(), list[1])
    local sent = requests[#requests]
    eq("background: a stop names the item", sent.op, "background.stop")
    eq("background: with its token", sent.args.stopToken, "tok-shell")
    -- The reply came first, the item is still listed: still stopping.
    vim.wait(100, function()
      return false
    end, 10)
    eq("background: still stopping while it is listed", (background.stopping(list[1]) or {}).status, "pending")
    handlers.background {
      hostId = hosts.selected(),
      agentId = "a1",
      items = { list[2] },
    }
    vim.wait(200, function()
      return #background.list("a1", hosts.selected()) == 1
    end, 10)
    eq("background: an update replaces the list", #background.list("a1", hosts.selected()), 1)
    eq("background: and clears the stop it answers", background.stopping(list[1]), nil)

    -- A refused stop stays on the row, even after the item has gone.
    stop_reply = "Background work is no longer available to stop"
    local heartbeat = background.list("a1", hosts.selected())[1]
    local answered
    background.stop("a1", hosts.selected(), heartbeat, function(err)
      answered = err
    end)
    vim.wait(200, function()
      return answered ~= nil
    end, 10)
    truthy("background: a refused stop says why", (answered or ""):find("no longer", 1, true), answered)
    handlers.background { hostId = hosts.selected(), agentId = "a1", items = {} }
    vim.wait(200, function()
      return background.list("a1", hosts.selected())[1] ~= nil
        and background.list("a1", hosts.selected())[1].gone == true
    end, 10)
    local kept = background.list("a1", hosts.selected())
    eq("background: the failed one is kept, marked gone", kept[1] and kept[1].gone, true)
    background.dismiss(kept[1])
    eq("background: until dismissed", #background.list("a1", hosts.selected()), 0)

    -- Something that cannot be stopped is never sent.
    local refused
    background.stop("a1", hosts.selected(), { id = "x", kind = "shell", canStop = false }, function(err)
      refused = err
    end)
    truthy("background: an unstoppable item is not sent", refused ~= nil)

    -- A reconnect: the stream's later snapshot lists every followed agent again.
    local before = #requests
    handlers.background_resync { hostId = hosts.selected() }
    vim.wait(200, function()
      for i = before + 1, #requests do
        if requests[i].op == "background.list" then
          return true
        end
      end
      return false
    end, 10)
    local relisted = false
    for i = before + 1, #requests do
      relisted = relisted or (requests[i].op == "background.list" and requests[i].args.agentId == "a1")
    end
    truthy("background: a resync lists again", relisted)

    -- The list `gb` opens: one row per item, the kind on the right.
    require("paseo.ui.background").open("a1", hosts.selected(), { title = "dev" })
    vim.wait(200, function()
      local view = require("paseo.ui.background")._view()
      return view and #background.list("a1", hosts.selected()) == 2
    end, 10)
    local items, title = require("paseo.ui.background").items("a1", hosts.selected(), "dev")
    eq("background: the list has a row each", #items, 2)
    truthy("background: titled with the count", title:find("1 of 2 running", 1, true), title)
    truthy("background: the kind is a column", items[2].right[2][1]:find("heartbeat", 1, true), items[2].right[2][1])
    require("paseo.ui.background").close()
  end)

  pcall(function()
    require("paseo.ui.background").close()
  end)
  bridge.on, bridge.request = old_on, old_request
  bridge.ensure, bridge.running = old_ensure, old_running
  background._reset()
  agents._apply { kind = "snapshot", entries = {} }
  if not ok then
    error(failure, 0)
  end
end

local function test_background_agents()
  local agents = require "paseo.agents"
  local hosts = require "paseo.hosts"
  local cfg = require("paseo.config").get().ui.float.rail
  local was = cfg.show_background
  local ok, failure = pcall(function()
    local root = vim.fn.tempname()
    cfg.show_background = false
    agents._apply {
      kind = "snapshot",
      hostId = hosts.selected(),
      entries = {
        { id = "mine", status = "idle", cwd = root, workspaceId = "w1" },
        -- An agent started for itself: busy, and none of your business.
        { id = "bg", status = "running", cwd = root, workspaceId = "w1", background = true },
      },
    }
    local ids = vim.tbl_map(function(a)
      return a.id
    end, agents.all())
    eq("background agents: left out of the list", ids, { "mine" })
    eq("background agents: and out of a directory's", #agents.for_root(root), 1)
    eq("background agents: and out of a workspace's", #agents.for_workspace { id = "w1", directory = root }, 1)
    eq("background agents: so its turn does not make the workspace run", agents.workspace_bucket(root), "done")
    truthy("background agents: still there by id", agents.get "bg" ~= nil)

    cfg.show_background = true
    agents._apply {
      kind = "snapshot",
      hostId = hosts.selected(),
      entries = {
        { id = "mine", status = "idle", cwd = root, workspaceId = "w1" },
        { id = "bg", status = "running", cwd = root, workspaceId = "w1", background = true },
      },
    }
    eq("background agents: shown with show_background", #agents.all(), 2)
    eq("background agents: and then counted", agents.workspace_bucket(root), "running")
  end)
  cfg.show_background = was
  agents._apply { kind = "snapshot", entries = {} }
  if not ok then
    error(failure, 0)
  end
end

--- Turn stats (Paseo 0.17): a dim footer under a finished turn, and the
--- session's totals on the Usage panel.
local function test_turn_stats()
  local timeline = require "paseo.ui.timeline"
  local metrics = {
    { label = "Model", value = "opus" },
    { label = "Elapsed", value = "12.3s" },
    { label = "Tokens", value = "8.1k in / 1.2k out" },
    { label = "Cache", value = "91%", tone = "ok" },
    { label = "Cost", value = "$0.0412", tone = "danger" },
  }
  local function text(lines)
    local out = {}
    for _, line in ipairs(lines) do
      local row = {}
      for _, cell in ipairs(line) do
        row[#row + 1] = cell[1]
      end
      out[#out + 1] = table.concat(row)
    end
    return out
  end
  local wide = timeline.card({ kind = "metrics", metrics = metrics }, { width = 120, gap = false })
  eq(
    "stats: one line, the model left to the bar",
    text(wide.lines),
    { " Elapsed 12.3s · Tokens 8.1k in / 1.2k out · Cache 91% · Cost $0.0412" }
  )
  local hls = {}
  for _, cell in ipairs(wide.lines[1]) do
    hls[cell[1]] = cell[2]
  end
  eq("stats: a tone colours its value", hls["91%"], "PaseoToolOk")
  eq("stats: and danger is danger", hls["$0.0412"], "PaseoToolFail")
  eq("stats: no tone is dim", hls["12.3s"], "PaseoDim")

  local narrow = timeline.card({ kind = "metrics", metrics = metrics }, { width = 30, gap = false })
  eq("stats: a narrow window breaks between metrics", text(narrow.lines), {
    " Elapsed 12.3s",
    " Tokens 8.1k in / 1.2k out",
    " Cache 91% · Cost $0.0412",
  })
  eq(
    "stats: only a model is nothing",
    #timeline.card({ kind = "metrics", metrics = { { label = "Model", value = "x" } } }, { width = 80, gap = false }).lines,
    0
  )

  -- The Usage panel's Session section.
  local bridge = require "paseo.bridge"
  local old_ensure, old_request = bridge.ensure, bridge.request
  bridge.ensure = function(fn)
    fn(nil)
  end
  bridge.request = function(_, _, cb)
    cb(nil, { providers = {} })
  end
  local ok, failure = pcall(function()
    local drawn = {}
    for _, line in ipairs(require("paseo.ui.panels.usage").lines({
      session_metrics = { { label = "Tokens", value = "40k in / 9k out" }, { label = "Cost", value = "$1.20" } },
    }, 100)) do
      local row = {}
      for _, cell in ipairs(line) do
        row[#row + 1] = cell[1] or ""
      end
      drawn[#drawn + 1] = table.concat(row)
    end
    local all = table.concat(drawn, "\n")
    truthy("stats: the usage panel has a Session section", all:find("Session", 1, true), all)
    truthy("stats: with its figures, aligned", all:find("Cost%s+%$1%.20"), all)
    truthy("stats: and is not 'no usage'", not all:find("no usage reported yet", 1, true), all)
  end)
  bridge.ensure, bridge.request = old_ensure, old_request
  if not ok then
    error(failure, 0)
  end
end

return {
  { "turn stats", test_turn_stats },
  { "background", test_background },
  { "background agents", test_background_agents },
}
