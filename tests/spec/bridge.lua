--- The sidecar's half of that conversation.

local t = require "tests.spec.helpers"
local eq, truthy = t.eq, t.truthy

local sidecar_source = t.sidecar_source

local function test_bridge()
  local bridge = require "paseo.bridge"

  -- The regression: this resolved through the runtimepath, and lazy.nvim
  -- resolves Lua modules through its own loader -- so `require` worked while
  -- the plugin directory was not yet on `rtp`, and the sidecar "could not
  -- start" on a plugin that was installed and working.
  local found = vim.api.nvim_get_runtime_file("sidecar/paseo-bridge.ts", false)[1]
  truthy(
    "bridge: the sidecar script is on disk",
    found ~= nil or vim.uv.fs_stat(vim.fn.getcwd() .. "/sidecar/paseo-bridge.ts") ~= nil
  )
  truthy("bridge: not running before it is started", not bridge.running())

  -- Every module has to at least load: a syntax error in one of these only
  -- shows up when you press the key, which is the worst time to find it.
  for _, name in ipairs {
    "paseo.ui.chat",
    "paseo.ui.session",
    "paseo.workspaces",
    "paseo.pickers.sessions",
    "paseo.pickers.workspaces",
  } do
    truthy("bridge: " .. name .. " loads", (pcall(require, name)))
  end

  -- The regression: `id` is the request-correlation field and bridge.request
  -- sets it LAST, so anything in args called `id` is silently replaced by the
  -- request number. An agent passed that way reached the daemon as "4" and was
  -- rejected as an ambiguous prefix across three agents.
  local source = sidecar_source()
  if source ~= "" then
    truthy(
      "bridge: no op takes its agent under the reserved key `id`",
      source:find 'need%(req%.id, "id"%)' == nil
    )

    -- The regression: `agent.ensure` created agents with a bare `cwd`, so the
    -- daemon provisioned a workspace for the directory it was handed. Inside a
    -- Paseo-cut WORKTREE -- itself a git repository -- that meant a second
    -- PROJECT named after the worktree directory, holding a duplicate
    -- workspace over the same files. Opening a chat in a workspace this plugin
    -- had just made was enough, and the app showed the work twice.
    --
    -- Agents go through a workspace handle. Both of them, forever.
    truthy(
      "bridge: no agent is created off the bare api, only through a workspace",
      source:find("api.agents.create", 1, true) == nil
    )
    truthy(
      "bridge: and the owning workspace is looked up before one is opened",
      source:find("function workspaceFor", 1, true) ~= nil
    )

    -- THE REGRESSION THAT COST SIXTEEN CORES. When Neovim died the sidecar's
    -- stdout became a pipe with no reader, every write failed with EPIPE, and
    -- the uncaughtException handler reported that by writing to stdout -- so
    -- the handler for the failure was the cause of the next one. 202 million
    -- write(2) calls that moved 1153 bytes between them, at 90% of a core,
    -- for as long as the machine was up.
    --
    -- Both halves are load-bearing and neither is obviously necessary on its
    -- own, which is why they are asserted rather than trusted: a guarded write
    -- that still reports failures by writing is the same bug.
    truthy(
      "bridge: the write path gives up once the pipe is broken",
      source:find("if (broken) return", 1, true) ~= nil
    )
    truthy(
      "bridge: and the error handler does not write into a broken pipe",
      source:find("if (broken || bailing) return", 1, true) ~= nil
    )
    -- On bun -- which is the runtime `runtime()` picks -- the watchdog is the
    -- ONLY thing that exits: bun delivers stdin EOF before the stdout error,
    -- so the write that would trip the broken flag never happens. Deleting
    -- this because node exits without it regresses every bun user to a
    -- permanently hung orphan.
    truthy(
      "bridge: and shutdown has a deadline",
      source:find("setTimeout(() => process.exit(code)", 1, true) ~= nil
    )
  end

  -- The same regression, executed rather than read: orphan.sh severs the read
  -- ends of a live sidecar and gives it five seconds to notice. Against the
  -- code that shipped this fails, having burnt a full core-second per second.
  local orphan = vim.fs.joinpath(vim.fn.getcwd(), "tests", "orphan.sh")
  if vim.uv.fs_stat(orphan) and vim.fn.executable "node" == 1 then
    local run = vim.system({ orphan }, { text = true }):wait(90000)
    truthy(
      "bridge: the sidecar dies when its stdout does",
      run.code == 0,
      (run.stdout or "") .. (run.stderr or "")
    )
  end

  -- VimLeavePre does not come back, so a teardown that waits for a round trip
  -- is a teardown that never happens -- which is how the orphans were made.
  -- Closing stdin is the part that has to be unconditional.
  local lua_bridge = io.open(vim.fn.getcwd() .. "/lua/paseo/bridge.lua", "r")
  if lua_bridge then
    local source = lua_bridge:read "*a"
    lua_bridge:close()
    truthy(
      "bridge: stop() closes stdin whatever the sidecar says",
      source:find("handle:write(nil)", 1, true) ~= nil
    )
    truthy(
      "bridge: stop() does not wait for a reply to kill",
      source:find("handle:kill(15)", 1, true) ~= nil
    )
    -- Two ensure() calls during an autostart used to spawn two sidecars and
    -- orphan the first.
    truthy(
      "bridge: a boot in flight is not started twice",
      source:find("if state.starting then", 1, true) ~= nil
    )
  end

  -- The sending code moved from explain.lua into the chat window when the
  -- chat became the primary surface; the rule did not move with it by itself.
  local chat = io.open(vim.fn.getcwd() .. "/lua/paseo/ui/chat.lua", "r")
  if chat then
    local source = chat:read "*a"
    chat:close()
    truthy(
      "bridge: the chat sends `agentId`, not `id`",
      source:find("agentId = chat.agent_id", 1, true) ~= nil
    )
  end

  local init = assert(io.open(vim.fn.getcwd() .. "/lua/paseo/init.lua", "r"))
  local init_source = init:read "*a"
  init:close()
  truthy(
    "bridge: `agents` is the canonical agent-session command",
    init_source:find("commands.agents =", 1, true) ~= nil
  )
  truthy(
    "bridge: `sessions` remains a compatibility alias",
    init_source:find("commands.sessions = commands.agents", 1, true) ~= nil
  )
  truthy(
    "bridge: `agent-settings` is canonical and `session` remains an alias",
    init_source:find('commands["agent-settings"] =', 1, true) ~= nil
      and init_source:find('commands.session = commands["agent-settings"]', 1, true) ~= nil
  )
end

return {
  { "bridge", test_bridge },
}
