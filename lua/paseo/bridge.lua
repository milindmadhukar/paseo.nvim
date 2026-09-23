--- The Lua half of the sidecar: spawn it once per session, speak JSON lines.
---
--- Every call is asynchronous. There is no synchronous variant on purpose --
--- a blocking round trip to a daemon is exactly the 2.4-second CLI experience
--- this whole arrangement exists to avoid.

local config = require "paseo.config"
local daemon = require "paseo.daemon"
local hosts = require "paseo.hosts"

local M = {}

---@class paseo.Bridge
---@field host_id string
---@field handle vim.SystemObj|nil
---@field next_id integer
---@field pending table<integer, fun(err: string|nil, result: table|nil)>
---@field buffer string
---@field ready boolean
---@field starting boolean a spawn is in flight; `handle` is not set yet
---@field waiting fun(err: string|nil)[] callers queued behind that spawn
---@type table<string, paseo.Bridge>
local states = {}
---@type table<string, fun(payload: table)[]>
local listeners = {}

local function state_for(host_id)
  host_id = host_id or hosts.selected()
  if not states[host_id] then
    states[host_id] = {
      host_id = host_id,
      handle = nil,
      next_id = 0,
      pending = {},
      buffer = "",
      ready = false,
      starting = false,
      waiting = {},
    }
  end
  return states[host_id]
end

---Resolve everyone who queued behind a boot, exactly once.
---
---`state.handle` is nil for the WHOLE of an autostart -- daemon.start polls
---every 400ms for up to 20 seconds -- and the old code guarded only on
---`state.handle`. Every ensure() in that window saw "not running" and spawned
---its own sidecar; the last assignment to state.handle won and the rest were
---orphaned with their stdin still open, so nothing ever told them to exit.
---That is how one leak per session became sixteen.
---@param state paseo.Bridge
---@param err string|nil
local function settle(state, err)
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
local function on_line(state, line)
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
    message.hostId = state.host_id
    for _, fn in ipairs(listeners[message.event] or {}) do
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
local function on_stdout(state, _, chunk)
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
        on_line(state, line)
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
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end

---@param host_id? string
---@return boolean
function M.running(host_id)
  if host_id then
    return state_for(host_id).handle ~= nil
  end
  for _, state in pairs(states) do
    if state.handle then
      return true
    end
  end
  return false
end

---Start one host's sidecar process. Connections are attempted after it exists.
---@param state paseo.Bridge
---@param callback fun(err: string|nil)
local function spawn(state, callback)
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
    stdout = function(_, chunk)
      on_stdout(state, nil, chunk)
    end,
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
      hosts.update(state.host_id, { status = "offline" })
      -- A sidecar that dies DURING its own boot must not leave `starting` set:
      -- every later ensure() would queue behind a spawn that is already over.
      settle(state, "sidecar exited")
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
  callback(nil)
end

---@param state paseo.Bridge
---@param host paseo.Host
---@param connection table
---@param callback fun(options: table|nil, err: string|nil)
local function connection_options(state, host, connection, callback)
  if connection.type ~= "local" then
    local options, err = hosts.connection_options(connection)
    return callback(options, err)
  end

  local endpoint = select(1, daemon.resolve())
  if endpoint then
    return callback({ url = endpoint.ws, password = hosts.secret(connection.password) }, nil)
  end
  if connection.autostart == false or config.get().paseo.autostart == false then
    return callback(nil, "no local Paseo daemon answered; see :checkhealth paseo")
  end
  vim.notify("paseo: no daemon answered — starting one…", vim.log.levels.INFO)
  daemon.start({}, function(started, err)
    if not started then
      return callback(nil, err or "could not start the local daemon")
    end
    vim.notify("paseo: daemon up", vim.log.levels.INFO)
    callback({ url = started.ws, password = hosts.secret(connection.password) }, nil)
  end)
end

---@param state paseo.Bridge
---@param host paseo.Host
---@param index integer
---@param errors string[]
local function connect_next(state, host, index, errors)
  local connection = host.connections[index]
  if not connection then
    local err = #errors > 0 and table.concat(errors, "; ") or "no usable connection"
    hosts.update(host.id, { status = "error", error = err, active_connection = vim.NIL })
    return settle(state, err)
  end

  hosts.update(host.id, {
    status = "connecting",
    error = vim.NIL,
    active_connection = connection.id,
  })
  local began = vim.uv.now()
  connection_options(state, host, connection, function(options, option_err)
    if option_err or not options then
      errors[#errors + 1] = connection.id .. ": " .. tostring(option_err)
      return connect_next(state, host, index + 1, errors)
    end
    options.hostId = host.id
    M.request("connect", options, function(err, result)
      if err then
        -- Never include the target or secret-bearing offer in this string.
        errors[#errors + 1] = connection.id .. ": " .. tostring(err)
        return connect_next(state, host, index + 1, errors)
      end
      result = result or {}
      if options.expectedServerId and result.serverId ~= options.expectedServerId then
        errors[#errors + 1] = connection.id .. ": daemon identity did not match pairing offer"
        return connect_next(state, host, index + 1, errors)
      end
      if host.server_id and result.serverId and host.server_id ~= result.serverId then
        errors[#errors + 1] = connection.id .. ": connection belongs to a different daemon"
        return connect_next(state, host, index + 1, errors)
      end
      hosts.update(host.id, {
        status = "online",
        error = vim.NIL,
        server_id = result.serverId,
        hostname = result.hostname,
        version = result.version,
        active_connection = connection.id,
        latency = math.max(0, vim.uv.now() - began),
      })
      settle(state, nil)
    end, host.id)
  end)
end

---Start one host runtime and connect it using that profile's ordered candidates.
---@param callback? fun(err: string|nil)
---@param host_id? string
function M.start(callback, host_id)
  callback = callback or function() end
  local host = hosts.get(host_id)
  if not host then
    return callback("unknown Paseo host " .. tostring(host_id))
  end
  local state = state_for(host.id)

  -- BEFORE the handle check, not after: `spawn` sets state.handle and only
  -- then sends `connect`, so there is a window where the sidecar exists and
  -- has not reached the daemon. Callers queue through that window rather than
  -- being told everything is fine.
  if state.starting then
    table.insert(state.waiting, callback)
    return
  end

  if state.handle then
    if host.status == "online" then
      return callback(nil)
    end
    state.starting = true
    state.waiting = { callback }
    return connect_next(state, host, 1, {})
  end

  state.starting = true
  state.waiting = { callback }
  spawn(state, function(err)
    if err then
      hosts.update(host.id, { status = "error", error = err })
      return settle(state, err)
    end
    connect_next(state, host, 1, {})
  end)
end

---Send one request.
---@param op string
---@param args? table
---@param callback? fun(err: string|nil, result: table|nil)
---@param host_id? string
function M.request(op, args, callback, host_id)
  callback = callback or function() end
  host_id = host_id or (args and args.hostId) or hosts.selected()
  local host = hosts.get(host_id)
  if not host then
    return callback("unknown Paseo host " .. tostring(host_id))
  end
  local state = state_for(host.id)

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

---Start a particular host if needed, then run `fn`.
---@param fn fun(err: string|nil)
---@param host_id? string
function M.ensure(fn, host_id)
  local host = hosts.get(host_id)
  if not host then
    return fn("unknown Paseo host " .. tostring(host_id))
  end
  local state = state_for(host.id)
  if state.handle and state.ready then
    if host.status == "online" then
      return fn(nil)
    end
  end
  M.start(fn, host.id)
end

---Restart a host runtime and re-run connection selection.
function M.reconnect(host_id, callback)
  M.stop(100, host_id)
  M.start(callback, host_id)
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
---@param host_id? string stop one host; absent stops every host
function M.stop(timeout, host_id)
  if not host_id then
    local ids = {}
    for id in pairs(states) do
      ids[#ids + 1] = id
    end
    for _, id in ipairs(ids) do
      M.stop(timeout, id)
    end
    return
  end
  local state = states[host_id]
  if not state then
    return
  end
  local handle = state.handle
  if not handle then
    return
  end

  local replied = false
  M.request("close", {}, function()
    replied = true
  end, host_id)

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
  settle(state, "sidecar stopped")
  for id, pending in pairs(state.pending) do
    state.pending[id] = nil
    pcall(pending, "sidecar stopped", nil)
  end
  hosts.update(host_id, { status = "offline" })
end

return M
