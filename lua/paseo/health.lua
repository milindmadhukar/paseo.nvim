--- `:checkhealth paseo`
---
--- Split into hard requirements (the review layer), and the Paseo backend
--- (which degrades to the `local` backend rather than breaking anything).

local config = require "paseo.config"

local M = {}

local start, ok, warn, err, info =
  vim.health.start, vim.health.ok, vim.health.warn, vim.health.error, vim.health.info

---Run `<exe> --version`.
---
---Only ever called for `bun` and `node`. NOT for `paseo`: that binary is the
---Electron desktop app, and running it opens a window.
---Run `<exe> --version`.
---
---Only ever called for `bun` and `node`. NEVER for `paseo`: that binary is the
---Electron desktop app, and running it opens a window.
---@param exe string
---@return string|nil version line
local function version_of(exe)
  if vim.fn.executable(exe) == 0 then
    return nil
  end
  local res = vim.system({ exe, "--version" }, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  return vim.split(res.stdout or "", "\n")[1]
end

local function check_core()
  start "paseo.nvim: requirements"

  if vim.fn.has "nvim-0.10" == 1 then
    ok("neovim " .. tostring(vim.version()))
  else
    err "neovim 0.10+ is required (vim.system, vim.fs.dir, vim.validate)"
  end

  local git = version_of "git"
  if git then
    ok(git)
  else
    err "`git` is not executable; nothing in this plugin works without it"
  end

  for name, why in pairs {
    ["gitsigns"] = "the staging and preview surface",
    ["telescope"] = "the changed-files and workspace pickers",
  } do
    if pcall(require, name) then
      ok(("%s is available (%s)"):format(name, why))
    else
      warn(("%s is not loaded -- it may just be lazy; needed for %s"):format(name, why))
    end
  end
end

local function check_paseo()
  local cfg = config.get()
  local daemon = require "paseo.daemon"
  start "paseo.nvim: Paseo backend"

  if cfg.backend ~= "paseo" then
    info(('backend is "%s"; the Paseo checks below are informational'):format(cfg.backend))
  end

  -- WHICH `paseo` is on PATH matters, and it is worth reporting.
  --
  -- There are two executables. `/usr/bin/paseo` is the CLI: a wrapper that
  -- execs the Electron binary with ELECTRON_RUN_AS_NODE=1, so it runs as plain
  -- Node -- headless, clean stdout, parseable --json. `/opt/Paseo/Paseo` is
  -- the desktop app, and running THAT opens a window and writes startup logs
  -- into whatever you were trying to parse.
  --
  -- A stale symlink from a CLI-only install can leave the desktop binary
  -- shadowing the CLI, which looks exactly like the CLI being broken.
  if vim.fn.executable "paseo" == 1 then
    local resolved = vim.fn.resolve(vim.fn.exepath "paseo")
    if resolved:match "resources/bin/paseo$" then
      ok(("`paseo` -> %s (the headless CLI)"):format(resolved))
    else
      warn(
        ("`paseo` resolves to %s, the DESKTOP binary -- running it opens a window. "):format(
          resolved
        ) .. "Point it at /usr/bin/paseo instead."
      )
    end
    info "nothing here shells out to it regardless; the daemon is reached over its WebSocket"
  end

  -- Endpoint discovery, reported candidate by candidate: "no daemon" and
  -- "a daemon somewhere else" look identical from a single failed probe.
  if vim.fn.executable "curl" == 0 then
    info "`curl` not found; skipped daemon discovery"
    return
  end

  local found = false
  for _, endpoint in ipairs(daemon.candidates()) do
    local probe = daemon.probe(endpoint)
    local label = ("%s (%s)"):format(endpoint.ws, endpoint.source)

    if probe.needs_password then
      -- Still a hit. A daemon that wants a password is a daemon.
      warn(("%s -> 401, daemon is up but wants a password"):format(label))
      found = true
      break
    elseif probe.reachable then
      local version = probe.info and probe.info.version or "?"
      local host = probe.info and probe.info.hostname or "?"
      ok(("%s -> up, Paseo %s on %s"):format(label, version, host))
      found = true
      break
    else
      info(("%s -> no answer"):format(label))
    end
  end

  if not found then
    warn "no daemon answered; start the Paseo app, then re-run this check"
  end

  -- The sidecar's runtime. Bun is preferred (it is what the rest of the stack
  -- uses); node >= 22 also satisfies @getpaseo/client.
  local bun = version_of "bun"
  local node = version_of "node"
  if bun then
    ok("bun " .. bun .. " (sidecar runtime)")
  elseif node then
    ok("node " .. node .. " (sidecar runtime; bun is preferred)")
  else
    warn "neither bun nor node found; the push-based agent status column needs one"
  end
end

function M.check()
  check_core()
  check_paseo()
end

return M
