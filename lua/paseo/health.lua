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
    ["gitsigns"] = "finding the hunk under the cursor (`:Paseo ask hunk`)",
    ["telescope"] = "the workspace and session pickers",
  } do
    if pcall(require, name) then
      ok(("%s is available (%s)"):format(name, why))
    else
      warn(("%s is not loaded -- it may just be lazy; needed for %s"):format(name, why))
    end
  end

  -- volt is REQUIRED, not recommended. Every surface but the transcript is
  -- drawn as volt extmarks -- the dashboard chrome, the six panels, the
  -- settings popup and the permission dialog -- and there is no longer a
  -- plain-text fallback behind them, because a fallback that has to be kept in
  -- step with the real renderer is a second renderer nobody tests.
  if not pcall(require, "volt") then
    err "nvzone/volt is not installed -- it is a hard dependency; no UI will open"
  elseif not pcall(require, "volt.ui") then
    -- A partial volt install is its own failure mode: `volt` resolves but
    -- `volt.ui` does not, and every panel comes up empty with no error anyone
    -- sees. Probe the submodule the panels actually use.
    err "volt is present but volt.ui is not -- update nvzone/volt; the panels cannot draw"
  else
    ok "volt is available (every surface but the transcript is drawn with it)"
  end

  -- Which palette volt derives from, because it changes what the chat looks
  -- like and is the first thing to check when the colours look wrong.
  info(
    vim.g.base46_cache and "volt colours come from base46 (NvChad)"
      or "volt colours are derived from Normal/Comment"
  )
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

      -- The terminal surface degrades rather than failing, so say which half
      -- you are getting. Without `terminal-restore-modes` a terminal opens on
      -- a blank screen and fills as it produces output, instead of showing you
      -- the session you just joined -- which looks like a broken attach and is
      -- really an old daemon.
      local features = (probe.info and probe.info.features) or {}
      if features["terminal-restore-modes"] then
        ok "terminals restore their scrollback on attach"
      else
        info "this daemon has no terminal-restore-modes; attaching falls back to a plain capture"
      end

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

---Pasting an image needs a helper. Neovim's own clipboard is text, so a
---missing reader is not a broken install -- it is the difference between
---<C-v> working in the composer and `:Paseo image <path>` being the only way.
local function check_images()
  start "paseo.nvim: images"

  local usable, installed = {}, {}
  for _, reader in ipairs(require("paseo.image").readers()) do
    installed[#installed + 1] = reader.name
    if reader.available then
      usable[#usable + 1] = reader.name
    end
  end

  if #usable > 0 then
    ok(("clipboard images via %s"):format(table.concat(usable, ", ")))
  else
    warn(
      "no usable clipboard image reader: install wl-paste (Wayland), xclip (X11) "
        .. "or pngpaste (macOS). `:Paseo image <path>` works regardless."
    )
    info(("looked for: %s"):format(table.concat(installed, ", ")))
  end
end

function M.check()
  check_core()
  check_paseo()
  check_images()
end

return M
