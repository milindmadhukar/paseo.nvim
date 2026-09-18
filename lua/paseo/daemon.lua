--- Finding the Paseo daemon.
---
--- The port is not a constant. `daemon.listen` in `$PASEO_HOME/config.json` is
--- the daemon's own answer, and 6767 is only what it happens to default to, so
--- hardcoding it works right up until someone moves it.
---
--- Resolution order, and the probe below, follow Paseo's own VS Code
--- extension, which is the reference implementation for "find the local
--- daemon".

local config = require "paseo.config"

local M = {}

---@class paseo.Endpoint
---@field host string
---@field port integer
---@field ws string      WebSocket URL, including the `/ws` path.
---@field status string  `GET` this to probe; see `probe()`.
---@field source string  Which rule produced it, for diagnostics.

---@return string  `$PASEO_HOME`, or ~/.paseo.
function M.home()
  local cfg = config.get()
  return cfg.paseo.home or vim.env.PASEO_HOME or vim.fs.joinpath(vim.env.HOME, ".paseo")
end

---`daemon.listen` out of the daemon's own config file.
---@return string|nil  "host:port"
local function listen_from_config()
  local path = vim.fs.joinpath(M.home(), "config.json")
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read "*a"
  fd:close()

  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  local listen = vim.tbl_get(decoded, "daemon", "listen")
  return type(listen) == "string" and listen or nil
end

---@param listen string  "host:port"
---@param source string
---@return paseo.Endpoint|nil
local function from_listen(listen, source)
  -- Only TCP listens are reachable this way. A unix socket or a Windows pipe
  -- is a different transport; say so rather than building a URL that cannot
  -- connect.
  if listen:match "^%a[%w+.-]*:" and not listen:match "^%d" then
    local scheme = listen:match "^(%a[%w+.-]*):"
    if scheme ~= "http" and scheme ~= "https" and scheme ~= "ws" and scheme ~= "wss" then
      return nil
    end
  end

  local host, port = listen:match "^([^:]+):(%d+)$"
  if not host then
    return nil
  end

  -- 0.0.0.0 / :: mean "listening everywhere", which is not an address to dial.
  if host == "0.0.0.0" or host == "::" or host == "" then
    host = "127.0.0.1"
  end

  return {
    host = host,
    port = tonumber(port),
    ws = ("ws://%s:%s/ws"):format(host, port),
    status = ("http://%s:%s/api/status"):format(host, port),
    source = source,
  }
end

---Every candidate endpoint, best first.
---@return paseo.Endpoint[]
function M.candidates()
  local cfg = config.get()
  ---@type paseo.Endpoint[]
  local out = {}

  -- An explicit URL from setup() wins outright: the user has said where it is.
  if cfg.paseo.url then
    local host, port = cfg.paseo.url:match "^wss?://([^:/]+):(%d+)"
    if host then
      out[#out + 1] = {
        host = host,
        port = tonumber(port),
        ws = cfg.paseo.url,
        status = ("http://%s:%s/api/status"):format(host, port),
        source = "config",
      }
    end
  end

  local configured = listen_from_config()
  for _, candidate in ipairs {
    { vim.env.PASEO_ENDPOINT, "$PASEO_ENDPOINT" },
    { configured, "daemon.listen" },
  } do
    local endpoint = candidate[1] and from_listen(candidate[1], candidate[2])
    if endpoint then
      out[#out + 1] = endpoint
    end
  end

  -- The hardcoded default is a LAST RESORT, and only when the daemon's own
  -- config did not name a port.
  --
  -- Falling through to 6767 regardless meant that a config.json saying 6799,
  -- with nothing listening there, silently connected to whatever was on 6767 --
  -- a different daemon, with different agents, reporting success. Worse, it
  -- made autostart unreachable: there was always something to connect to, so
  -- the daemon that was actually configured never got started.
  if not configured then
    local fallback = from_listen("127.0.0.1:6767", "default")
    if fallback then
      out[#out + 1] = fallback
    end
  end

  return out
end

---@class paseo.Probe
---@field reachable boolean
---@field code integer|nil  HTTP status, when there was one.
---@field info table|nil    The decoded /api/status body.
---@field needs_password boolean

---Probe one endpoint.
---
---A **401 still means "found it"** -- the daemon is there and wants a
---password. Treating it as a miss and moving to the next candidate is how you
---end up reporting "no daemon" about a daemon that is running.
---@param endpoint paseo.Endpoint
---@param timeout? integer seconds
---@return paseo.Probe
function M.probe(endpoint, timeout)
  if vim.fn.executable "curl" == 0 then
    return { reachable = false, needs_password = false }
  end

  local cmd = {
    "curl",
    "-s",
    "-m",
    tostring(timeout or 3),
    "-w",
    "\n%{http_code}",
    endpoint.status,
  }
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return { reachable = false, needs_password = false }
  end

  local lines = vim.split(res.stdout or "", "\n")
  local status = tonumber(lines[#lines])
  local body = table.concat(lines, "\n", 1, math.max(#lines - 1, 1))

  if status == 401 then
    return { reachable = true, code = 401, needs_password = true }
  end
  if not status or status < 200 or status >= 300 then
    return { reachable = false, code = status, needs_password = false }
  end

  local decoded = select(2, pcall(vim.json.decode, body))
  return {
    reachable = true,
    code = status,
    info = type(decoded) == "table" and decoded or nil,
    needs_password = false,
  }
end

---The `paseo` CLI, if the one on PATH is actually the CLI.
---
---Two executables exist. `/usr/bin/paseo` is a wrapper that execs the Electron
---binary with `ELECTRON_RUN_AS_NODE=1` -- plain Node, no window.
---`/opt/Paseo/Paseo` is the desktop app, and running THAT opens a window on the
---user's desktop. A stale symlink from a CLI-only install can leave the second
---shadowing the first, so the path is resolved rather than trusted.
---@return string|nil path
function M.cli()
  local exe = vim.fn.exepath "paseo"
  if exe == "" then
    return nil
  end
  local resolved = vim.fn.resolve(exe)
  if resolved:match "resources/bin/paseo$" then
    return exe
  end
  return nil
end

---Start the local daemon, and wait for it to answer.
---
---Only ever called when nothing answered: `paseo daemon start` against a
---RUNNING daemon exits 1 and prints a wall of daemon logs, so "start it just in
---case" is not an option.
---@param opts? { timeout?: integer }  seconds to wait for it to come up
---@param callback fun(endpoint: paseo.Endpoint|nil, err: string|nil)
function M.start(opts, callback)
  opts = opts or {}

  local cli = M.cli()
  if not cli then
    local exe = vim.fn.exepath "paseo"
    if exe == "" then
      return callback(nil, "no daemon is running and `paseo` is not on PATH")
    end
    return callback(
      nil,
      ("no daemon is running, and `paseo` resolves to %s -- the desktop binary. "):format(
        vim.fn.resolve(exe)
      ) .. "Point it at /usr/bin/paseo, or start Paseo yourself."
    )
  end

  -- `--home` when one is configured, or the daemon starts against ~/.paseo and
  -- tries to bind 6767 -- which is somebody else's daemon.
  local argv = { cli, "daemon", "start" }
  local home = config.get().paseo.home
  if home then
    vim.list_extend(argv, { "--home", home })
  end

  vim.system(argv, { text = true }, function(result)
    vim.schedule(function()
      -- The exit code is not the whole story: the daemon forks, so a non-zero
      -- exit with a daemon that then answers is still a success. Reachability
      -- is the only thing worth believing.
      local deadline = vim.uv.now() + (opts.timeout or 20) * 1000
      local function poll()
        local endpoint = M.resolve()
        if endpoint then
          return callback(endpoint, nil)
        end
        if vim.uv.now() >= deadline then
          local detail =
            vim.trim((result.stderr or "") ~= "" and result.stderr or (result.stdout or ""))
          return callback(
            nil,
            "the daemon did not come up" .. (detail ~= "" and (": " .. detail:sub(1, 200)) or "")
          )
        end
        vim.defer_fn(poll, 400)
      end
      poll()
    end)
  end)
end

---The first candidate that answers.
---@return paseo.Endpoint|nil endpoint, paseo.Probe|nil probe
function M.resolve()
  for _, endpoint in ipairs(M.candidates()) do
    local probe = M.probe(endpoint)
    if probe.reachable then
      return endpoint, probe
    end
  end
  return nil, nil
end

return M
