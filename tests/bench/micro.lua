--- Micro benchmarks: the plugin's main-loop work, timed in isolation.
---
--- Run with `tests/bench/run.sh micro`. Headless, on the unit suite's init, so
--- the bridge is stubbed and nothing here touches a daemon: every reply is
--- canned, at the sizes a real day reaches (fifty workspaces, a hundred and
--- fifty agents, a long transcript).
---
--- What it times is what a key press waits on: building and painting the rail,
--- a spinner tick, one agent event fanning out, a reply streaming in, a
--- conversation loading, and the new-task screen working out where it is.
---
--- Output: one JSON object on the last line of stdout, `{ case: { p50, p90,
--- mean, n } }` in ms, for tests/bench/compare.py.

local perf = require "paseo.perf"
if vim.env.BENCH_PROFILE then
  dofile(vim.env.BENCH_PROFILE)
end

local SIZES = {
  workspaces = tonumber(vim.env.BENCH_WORKSPACES) or 50,
  agents_per = tonumber(vim.env.BENCH_AGENTS_PER) or 3,
  runs = tonumber(vim.env.BENCH_RUNS) or 20,
}

local results = {}

---@param samples number[]
local function summarise(samples)
  table.sort(samples)
  local n = #samples
  local total = 0
  for _, s in ipairs(samples) do
    total = total + s
  end
  local function q(p)
    return samples[math.max(1, math.min(n, math.ceil(p * n)))]
  end
  return { n = n, p50 = q(0.5), p90 = q(0.9), mean = total / n, max = samples[n] }
end

---Time `fn` `runs` times (after one warm-up) as `name`.
local only = vim.env.BENCH_ONLY
local function bench(name, fn, runs, setup)
  if only and not name:find(only, 1, true) then
    return
  end
  runs = runs or SIZES.runs
  if setup then
    setup()
  end
  fn() -- warm: first-call costs (require, JIT) are not what is being asked
  local samples = {}
  for _ = 1, runs do
    if setup then
      setup()
    end
    local t0 = vim.uv.hrtime()
    fn()
    samples[#samples + 1] = (vim.uv.hrtime() - t0) / 1e6
  end
  results[name] = summarise(samples)
  io.stdout:write(("%-34s p50 %8.2f ms   p90 %8.2f ms\n"):format(name, results[name].p50, results[name].p90))
end

-- ------------------------------------------------------------------ fixture

local root = vim.fn.tempname() .. "-bench"
vim.fn.mkdir(root, "p")
local project = root .. "/project"
vim.fn.mkdir(project, "p")
vim.fn.system { "git", "-C", project, "init", "-q" }

local host = require("paseo.hosts").selected()

local workspaces = {}
local entries = {}
for i = 1, SIZES.workspaces do
  local dir = ("%s/wt/ws%02d"):format(root, i)
  vim.fn.mkdir(dir, "p")
  workspaces[#workspaces + 1] = {
    id = ("wks_%02d"):format(i),
    name = ("feature-%02d"):format(i),
    title = ("Feature number %d"):format(i),
    directory = dir,
    project = project,
    projectRoot = project,
    projectId = "prj_bench",
    branch = ("feature/%02d"):format(i),
    status = "idle",
    diffStat = { additions = i * 3, deletions = i },
  }
  for j = 1, SIZES.agents_per do
    local running = (i + j) % 10 == 0
    entries[#entries + 1] = {
      id = ("agent-%02d-%d"):format(i, j),
      title = ("Agent %d in %d"):format(j, i),
      status = running and "running" or "idle",
      cwd = dir,
      workspaceId = workspaces[#workspaces].id,
      provider = "fake",
      createdAt = ("2026-11-%02dT10:00:00Z"):format((i % 28) + 1),
    }
  end
end
-- The workspace the chat is in: the project itself.
workspaces[#workspaces + 1] = {
  id = "wks_main",
  name = "main",
  directory = project,
  project = project,
  projectRoot = project,
  projectId = "prj_bench",
  branch = "main",
  status = "idle",
}
entries[#entries + 1] = {
  id = "agent-main",
  title = "The chat",
  status = "idle",
  cwd = project,
  workspaceId = "wks_main",
  provider = "fake",
}

---A conversation of `n` items: prompts, answers with some markdown, tool calls.
local function history(n)
  local items = {}
  for i = 1, n do
    local k = i % 3
    if k == 0 then
      items[#items + 1] = { kind = "user", id = "u" .. i, text = "Please look at file " .. i }
    elseif k == 1 then
      items[#items + 1] = {
        kind = "text",
        id = "t" .. i,
        text = ("## Step %d\n\nSome **bold** words and `code`, then a list:\n\n- one\n- two\n- three\n\n"):rep(3):format(
          i,
          i,
          i
        ),
      }
    else
      items[#items + 1] = {
        kind = "tool",
        id = "c" .. i,
        callId = "c" .. i,
        name = "Bash",
        status = "completed",
        display = { displayName = "Bash", summary = "ls -la " .. i },
        detail = { type = "shell", command = "ls -la", output = ("line\n"):rep(20) },
      }
    end
  end
  return items
end

local HISTORY = history(tonumber(vim.env.BENCH_HISTORY) or 60)

-- ---------------------------------------------------------------- the stubs

local bridge = require "paseo.bridge"
bridge.ensure = function(cb)
  cb(nil)
end
bridge.running = function()
  return true
end
bridge.request = function(op, args, cb)
  cb = cb or function() end
  if op == "agent.find" then
    return cb(nil, { id = "agent-main", provider = "fake" })
  elseif op == "timeline.history" then
    return cb(nil, { items = HISTORY })
  elseif op == "workspaces.list" then
    return cb(nil, { entries = vim.deepcopy(workspaces) })
  elseif op == "agents.list" then
    return cb(nil, { entries = vim.deepcopy(entries) })
  elseif op == "subagents.list" then
    return cb(nil, { subagents = {} })
  end
  cb(nil, {})
end

require("paseo.agents")._apply { kind = "snapshot", hostId = host, entries = vim.deepcopy(entries) }
require("paseo.ui.chat").load_settings = function() end

-- --------------------------------------------------------------- the cases

local chat_mod = require "paseo.ui.chat"
local native = require "paseo.ui.native"
local rail = require "paseo.ui.rail"
local transcript = require "paseo.ui.transcript"

vim.cmd.cd(project)

-- OPEN A CHAT for real, on the native surface, with the rail beside it.
local opened
do
  local t0 = vim.uv.hrtime()
  chat_mod.open { root = project }
  vim.wait(5000, function()
    local c = chat_mod.current()
    return c ~= nil and c.agent_id ~= nil and c.initialised and not c.holding
  end, 1)
  opened = (vim.uv.hrtime() - t0) / 1e6
end
local chat = assert(chat_mod.current(), "no chat opened")
results["chat.open (stubbed)"] = { n = 1, p50 = opened, p90 = opened, mean = opened, max = opened }
io.stdout:write(("%-34s %8.2f ms\n"):format("chat.open (stubbed, once)", opened))

if not rail.win() then
  native.toggle_rail()
end
vim.wait(1000, function()
  return rail.win() ~= nil
end, 1)
vim.wait(50)
local rail_lines = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(rail.win()))
io.stdout:write(("rail shows %d lines for %d workspaces, %d agents\n"):format(rail_lines, #workspaces, #entries))
assert(rail_lines > SIZES.workspaces, "the rail did not load the fixture's workspaces")

bench("rail.build", function()
  rail.build(40)
end)

bench("rail.draw", function()
  rail.draw()
end)

bench("rail.spinner_tick", function()
  -- What the spinner clock does every 100 ms while anything runs.
  if rail.spinning() then
    rail.draw()
  end
end)

bench("rail.toggle (hide+show)", function()
  native.toggle_rail()
  native.toggle_rail()
end, 10)

-- ONE AGENT EVENT: a status flip, through every listener the plugin has --
-- the native surface's sync, the rail, every chat's header and relay.
local flip = false
bench("agents.event_fanout", function()
  flip = not flip
  require("paseo.agents")._apply {
    kind = "upsert",
    hostId = host,
    agent = vim.tbl_extend("force", entries[5], { status = flip and "running" or "idle" }),
  }
  -- The listeners schedule; let them run.
  vim.wait(0)
  vim.wait(5, function()
    return false
  end, 1)
end)

-- STREAMING: an answer arriving as 2000 small chunks, one block -- each
-- chunk on its own turn of the loop, as the bridge delivers them. Measured as
-- MAIN-LOOP time (inside the stream calls and the draws they cause), which is
-- what a key pressed meanwhile waits behind; the wall clock also includes
-- the loop idling between chunks.
local function feed(n, gap_ms)
  local busy = 0
  local transcript_flush = transcript.flush
  transcript.flush = function(...)
    local t0 = vim.uv.hrtime()
    transcript_flush(...)
    busy = busy + (vim.uv.hrtime() - t0) / 1e6
  end
  transcript.upsert(chat, { kind = "user", text = "go" })
  local i, done = 0, false
  local timer = vim.uv.new_timer()
  timer:start(0, gap_ms, vim.schedule_wrap(function()
    for _ = 1, gap_ms == 0 and 1 or 1 do
      i = i + 1
      if i > n then
        if not timer:is_closing() then
          timer:stop()
          timer:close()
        end
        done = true
        return
      end
      local t0 = vim.uv.hrtime()
      transcript.stream(chat, (i % 40 == 0) and "\n\n" or ("word%d "):format(i))
      busy = busy + (vim.uv.hrtime() - t0) / 1e6
    end
  end))
  vim.wait(120000, function()
    return done
  end, 1)
  transcript.close(chat)
  transcript.flush = transcript_flush
  return busy
end

do
  local samples = {}
  for _ = 1, 3 do
    samples[#samples + 1] = feed(2000, 1)
  end
  results["transcript.stream x2000 (loop ms)"] = summarise(samples)
  io.stdout:write(("%-34s p50 %8.2f ms   p90 %8.2f ms\n"):format(
    "transcript.stream x2000 (loop ms)",
    results["transcript.stream x2000 (loop ms)"].p50,
    results["transcript.stream x2000 (loop ms)"].p90
  ))
end

-- HISTORY: a conversation loading into a fresh transcript.
bench(("transcript.history x%d"):format(#HISTORY), function()
  transcript.reset(chat)
  for _, item in ipairs(HISTORY) do
    transcript.upsert(chat, vim.deepcopy(item))
  end
end, 10)

bench("transcript.redraw (resize)", function()
  transcript.redraw(chat)
end, 10)

bench("sidebar.header refresh", function()
  chat_mod.refresh(chat)
end)

-- THE NEW-TASK SCREEN'S FIRST QUESTION: where am I? In a git repo, then in a
-- directory of repos that has no manifest yet -- the case that walks.
local repos_dir = root .. "/multi"
for i = 1, 6 do
  local repo = ("%s/repo%d"):format(repos_dir, i)
  vim.fn.mkdir(repo .. "/node_modules/pkg", "p")
  vim.fn.system { "git", "-C", repo, "init", "-q" }
  vim.fn.writefile({ "node_modules/" }, repo .. "/.gitignore")
  for f = 1, 200 do
    vim.fn.writefile({ "x" }, ("%s/node_modules/pkg/f%d.js"):format(repo, f))
  end
end

local ws_mod = require "paseo.workspaces"
local repos = require "paseo.repos"
local registry = require "paseo.registry"
local function uncached()
  repos.invalidate()
  registry.invalidate()
end

bench("workspaces.strategy (git repo)", function()
  ws_mod.strategy(project)
end, 10, uncached)

bench("workspaces.strategy (repos dir)", function()
  ws_mod.strategy(repos_dir)
end, 5, uncached)

bench("workspaces.here", function()
  ws_mod.here(project)
end, 10, uncached)

-- THE WHOLE NEW-TASK OPEN, from the key to the cards, catalogue stubbed.
bench("new.open (repo)", function()
  require("paseo.new").open { root = project }
  vim.wait(0)
  local d = chat_mod.current()
  if d and d.draft then
    chat_mod.discard(d)
  end
end, 5)

io.stdout:write("\nspans recorded while benching (perf.lua):\n")
for _, line in ipairs(perf.lines()) do
  io.stdout:write(line, "\n")
end
io.stdout:write("\nJSON " .. vim.json.encode(results) .. "\n")
vim.fn.delete(root, "rf")
