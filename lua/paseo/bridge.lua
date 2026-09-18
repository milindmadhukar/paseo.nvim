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
local state = {
  handle = nil,
  next_id = 0,
  pending = {},
  listeners = {},
  buffer = "",
  ready = false,
}

---Where the sidecar script lives.
---
---Derived from THIS file's own path, not from the runtimepath. lazy.nvim
---resolves a plugin's Lua modules through its own loader, so `require` works
---long before the plugin directory is added to `rtp` -- and until it is,
---`nvim_get_runtime_file("bin/paseo-bridge.ts")` returns nothing. The sidecar
---then "could not start" on a plugin that was installed and working.
---@return string|nil
local function script_path()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    -- @<root>/lua/paseo/bridge.lua -> <root>/sidecar/paseo-bridge.ts
    local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source:sub(2))))
    local candidate = vim.fs.joinpath(root, "sidecar", "paseo-bridge.ts")
    if vim.uv.fs_stat(candidate) then
      return candidate
    end
  end
  return vim.api.nvim_get_runtime_file("sidecar/paseo-bridge.ts", false)[1]
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
  local ok, message = pcall(vim.json.decode, line)
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

---Subscribe to an event the sidecar emits (`text`, `turn`, `restored`,
---`replaced`, `stream_error`, `protocol_error`).
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
      for id, pending in pairs(state.pending) do
        state.pending[id] = nil
        pcall(pending, "sidecar exited", nil)
      end
    end)
  end)

  if not ok then
    return callback("could not start the sidecar: " .. tostring(handle))
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

  if state.handle then
    return callback(nil)
  end

  local endpoint = select(1, daemon.resolve())
  if endpoint then
    return spawn(endpoint, callback)
  end

  if config.get().paseo.autostart == false then
    return callback "no Paseo daemon answered; see :checkhealth paseo"
  end

  -- Nothing answered, so start one. This is why the plugin can be the only
  -- thing you open: the alternative is every agent action failing until you go
  -- and start the daemon by hand.
  vim.notify("paseo: no daemon answered — starting one…", vim.log.levels.INFO)
  daemon.start({}, function(started, err)
    if not started then
      return callback(err or "could not start the daemon")
    end
    vim.notify("paseo: daemon up", vim.log.levels.INFO)
    spawn(started, callback)
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

---Stop the sidecar.
function M.stop()
  if not state.handle then
    return
  end
  M.request("close", {}, function()
    if state.handle then
      state.handle:kill(15)
    end
  end)
end

return M
