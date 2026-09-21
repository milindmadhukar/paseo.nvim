--- The Lua half of the sidecar: spawn it once per session, speak JSON lines.
---
--- Every call is asynchronous. There is no synchronous variant on purpose --
--- a blocking round trip to a daemon is exactly the 2.4-second CLI experience
--- this whole arrangement exists to avoid.

local config = require "paseo.config"
local daemon = require "paseo.daemon"

local M = {}

---@class paseo.Bridge
---@field handle vim.SystemObj|nil
---@field next_id integer
---@field pending table<integer, fun(err: string|nil, result: table|nil)>
---@field listeners table<string, fun(payload: table)[]>
---@field buffer string
---@field ready boolean
---@field starting boolean a spawn is in flight; `handle` is not set yet
---@field waiting fun(err: string|nil)[] callers queued behind that spawn
local state = {
  handle = nil,
  next_id = 0,
  pending = {},
  listeners = {},
  buffer = "",
  ready = false,
  starting = false,
  waiting = {},
}

---Resolve everyone who queued behind a boot, exactly once.
---
---`state.handle` is nil for the WHOLE of an autostart -- daemon.start polls
---every 400ms for up to 20 seconds -- and the old code guarded only on
---`state.handle`. Every ensure() in that window saw "not running" and spawned
---its own sidecar; the last assignment to state.handle won and the rest were
---orphaned with their stdin still open, so nothing ever told them to exit.
---That is how one leak per session became sixteen.
---@param err string|nil
local function settle(err)
  if not state.starting then
    return
  end
  state.starting = false
  local waiting = state.waiting
  state.waiting = {}
  for _, fn in ipairs(waiting) do
    pcall(fn, err)
  end
end

---Where the sidecar script lives.
---
---|paseo.plugin| owns the "where is this plugin" question, and the reason it
---cannot be answered from the runtimepath is written there.
---@return string|nil
local function script_path()
  return require("paseo.plugin").file("sidecar", "paseo-bridge.ts")
end

---@return string[]|nil argv
local function runtime()
  local script = script_path()
  if not script then
    return nil
  end
  if vim.fn.executable "bun" == 1 then
    return { "bun", "run", script }
  end
  -- node needs the TypeScript stripped; 22.6+ can do it itself.
  if vim.fn.executable "node" == 1 then
    return { "node", "--experimental-strip-types", script }
  end
  return nil
end

---@param line string
local function on_line(line)
  -- `luanil` is not optional. Without it JSON `null` decodes to `vim.NIL`,
  -- which is a userdata value and therefore TRUTHY -- so `if not ws.archivingAt`
  -- was false for every workspace that had never been archived, and the list
  -- came back empty. Every optional field the daemon sends is affected:
  -- status, provider, cwd, branch, workspaceId. Decoding them as real nil is
  -- the only place this can be fixed once.
  local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(message) ~= "table" then
    return
  end

  if message.event then
    for _, fn in ipairs(state.listeners[message.event] or {}) do
      pcall(fn, message)
    end
    if message.event == "ready" then
      state.ready = true
    end
    return
  end

  local callback = message.id and state.pending[message.id]
  if not callback then
    return
  end
  state.pending[message.id] = nil

  -- NOT `message.ok and nil or message.error`. `nil` can never be the true
  -- branch of `a and b or c` in Lua -- `true and nil` is nil, which then falls
  -- through to `or`, so EVERY successful reply came back as an error.
  local err
  if not message.ok then
    err = message.error or "unknown error"
  end
  callback(err, message.result)
end

---@param chunk string
local function on_stdout(_, chunk)
  if not chunk then
    return
  end
  state.buffer = state.buffer .. chunk
  while true do
    local index = state.buffer:find "\n"
    if not index then
      break
    end
    local line = state.buffer:sub(1, index - 1)
    state.buffer = state.buffer:sub(index + 1)
    if line ~= "" then
      -- Back onto the main loop: handlers touch buffers and windows, and this
      -- runs on the libuv thread.
      vim.schedule(function()
        on_line(line)
      end)
    end
  end
end

---Subscribe to an event the sidecar emits.
---
---Conversation: `user`, `text`, `thinking`, `tool`, `todo`, `notice`,
---`compaction`. Everything but the first two used to be dropped at the
---sidecar, which is why the chat showed a silence while the agent worked.
---
---Permissions: `permission`, `permission_resolved`.
---
---Agent session: `settings`, `usage`, `attention`, `turn`.
---
---Connection: `restored`, `replaced`, `stream_error`, `protocol_error`,
---`ready`, `agents`.
---@param event string
---@param fn fun(payload: table)
function M.on(event, fn)
  state.listeners[event] = state.listeners[event] or {}
  table.insert(state.listeners[event], fn)
end

---@return boolean
function M.running()
  return state.handle ~= nil
end

---Start the sidecar and connect it to the daemon.
---@param callback? fun(err: string|nil)
---Start the sidecar, once an endpoint is known.
---@param endpoint paseo.Endpoint
---@param callback fun(err: string|nil)
local function spawn(endpoint, callback)
  local argv = runtime()
  if not argv then
    return callback "no bun or node found, and the sidecar needs one"
  end

  -- The sidecar's one dependency, installed on demand. A plugin manager will
  -- not have run `bun install` for us, and requiring a `build` step just for
  -- this would put a toolchain between the user and a working install.
  local script = assert(script_path())
  local sidecar_dir = vim.fs.dirname(script)
  if not vim.uv.fs_stat(vim.fs.joinpath(sidecar_dir, "node_modules", "@getpaseo", "client")) then
    if vim.fn.executable "bun" == 0 then
      return callback "the sidecar needs @getpaseo/client; install bun, or run `npm install` in the plugin's sidecar/ directory"
    end
    vim.notify("paseo: installing the sidecar's dependencies…", vim.log.levels.INFO)
    local install = vim.system({ "bun", "install" }, { cwd = sidecar_dir, text = true }):wait()
    if install.code ~= 0 then
      return callback("could not install the sidecar's dependencies: " .. (install.stderr or ""))
    end
  end

  local ok, handle = pcall(vim.system, argv, {
    stdin = true,
    text = true,
    cwd = sidecar_dir,
    stdout = on_stdout,
    stderr = function(_, chunk)
      if chunk and chunk ~= "" then
        vim.schedule(function()
          vim.notify("paseo-bridge: " .. chunk, vim.log.levels.DEBUG)
        end)
      end
    end,
  }, function()
    -- Exit: drop the handle so the next call respawns rather than writing into
    -- a dead pipe.
    vim.schedule(function()
      state.handle, state.ready, state.buffer = nil, false, ""
      -- A sidecar that dies DURING its own boot must not leave `starting` set:
      -- every later ensure() would queue behind a spawn that is already over.
      settle "sidecar exited"
      for id, pending in pairs(state.pending) do
        state.pending[id] = nil
        pcall(pending, "sidecar exited", nil)
      end
    end)
  end)

  if not ok then
    return callback("could not start the sidecar: " .. tostring(handle))
  end

  -- Belt and braces for the guard in M.start. Overwriting a live handle is
  -- what orphaned the sidecars in the first place, so if one is somehow
  -- already here, the NEWCOMER is the one that goes.
  if state.handle then
    pcall(function()
      handle:write(nil)
    end)
    pcall(function()
      handle:kill(15)
    end)
    return callback(nil)
  end
  state.handle = handle

  M.request("connect", {
    url = endpoint.ws,
    password = config.get().paseo.password,
  }, function(err)
    callback(err)
  end)
end

---Start the sidecar and connect it to the daemon, starting the daemon if
---nothing answers.
---@param callback? fun(err: string|nil)
function M.start(callback)
  callback = callback or function() end

  -- BEFORE the handle check, not after: `spawn` sets state.handle and only
  -- then sends `connect`, so there is a window where the sidecar exists and
  -- has not reached the daemon. Callers queue through that window rather than
  -- being told everything is fine.
  if state.starting then
    table.insert(state.waiting, callback)
    return
  end

  if state.handle then
    return callback(nil)
  end

  state.starting = true
  state.waiting = { callback }

  local endpoint = select(1, daemon.resolve())
  if endpoint then
    return spawn(endpoint, settle)
  end

  if config.get().paseo.autostart == false then
    return settle "no Paseo daemon answered; see :checkhealth paseo"
  end

  -- Nothing answered, so start one. This is why the plugin can be the only
  -- thing you open: the alternative is every agent action failing until you go
  -- and start the daemon by hand.
  vim.notify("paseo: no daemon answered — starting one…", vim.log.levels.INFO)
  daemon.start({}, function(started, err)
    if not started then
      return settle(err or "could not start the daemon")
    end
    vim.notify("paseo: daemon up", vim.log.levels.INFO)
    spawn(started, settle)
  end)
end

---Send one request.
---@param op string
---@param args? table
---@param callback? fun(err: string|nil, result: table|nil)
function M.request(op, args, callback)
  callback = callback or function() end

  if not state.handle then
    return callback "sidecar is not running"
  end

  state.next_id = state.next_id + 1
  local id = state.next_id
  state.pending[id] = callback

  -- `id` and `op` are set LAST and therefore win. Nothing in `args` may use
  -- those names; an agent is passed as `agentId` for exactly this reason.
  local payload = vim.tbl_extend("force", args or {}, { id = id, op = op })
  local ok, err = pcall(function()
    state.handle:write(vim.json.encode(payload) .. "\n")
  end)
  if not ok then
    state.pending[id] = nil
    callback("write failed: " .. tostring(err))
  end
end

---Start if needed, then run `fn`.
---@param fn fun(err: string|nil)
function M.ensure(fn)
  if state.handle and state.ready then
    return fn(nil)
  end
  M.start(fn)
end

---Stop the sidecar, synchronously enough for VimLeavePre.
---
---The old version asked for a close and killed the process from the REPLY
---callback. It is wired to VimLeavePre (lua/paseo/init.lua), which does not
---come back: Neovim exits before any round trip completes, so the kill was
---never reached and every session leaked a sidecar. Sixteen of them were found
---at 90% of a core each, one per editor that had been closed that day.
---
---So: ask nicely, wait a LITTLE, then stop asking. Closing stdin is the part
---that matters -- it is the EOF the sidecar exits on -- and it happens whether
---or not the reply arrived.
---@param timeout? integer ms to wait for the close reply before insisting (default 200)
function M.stop(timeout)
  local handle = state.handle
  if not handle then
    return
  end

  local replied = false
  M.request("close", {}, function()
    replied = true
  end)

  -- Nothing may write to or respawn onto this handle while it goes down.
  state.handle, state.ready = nil, false

  -- NOT fast_only: on_stdout hands its lines to the main loop with
  -- vim.schedule, and a fast-only wait never runs them -- so the reply could
  -- not be seen even when it is already sitting in the pipe.
  vim.wait(timeout or 200, function()
    return replied
  end, 10)

  pcall(function()
    handle:write(nil)
  end)
  pcall(function()
    handle:kill(15)
  end)
  -- SystemObj:wait sends SIGKILL itself when the timeout expires, so this is
  -- the last resort and needs no explicit kill(9).
  pcall(function()
    handle:wait(500)
  end)

  state.buffer = ""
  settle "sidecar stopped"
  for id, pending in pairs(state.pending) do
    state.pending[id] = nil
    pcall(pending, "sidecar stopped", nil)
  end
end

return M
