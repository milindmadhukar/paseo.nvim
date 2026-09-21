--- `:checkhealth paseo`
---
--- Split into hard requirements (the review layer), which work with nothing
--- running, and the daemon the agent half needs.

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

  if vim.fn.has "nvim-0.11" == 1 then
    ok("neovim " .. tostring(vim.version()))
  else
    err "neovim 0.11+ is required (vim.system, vim.fs.dir, vim.validate by name)"
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
  -- drawn as volt extmarks -- the dashboard chrome, the seven panels, the
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

  -- Where the palette comes from, because it changes what everything looks
  -- like and is the first thing to check when the colours look wrong.
  if vim.g.base46_cache then
    info "colours come from base46's palette (NvChad)"
  else
    info "colours are derived from Diagnostic*/Added/Removed/Function/Comment"
  end

  -- A Nerd Font cannot be detected from inside Neovim -- the terminal owns the
  -- font and tells us nothing about it. What CAN be checked is that the glyphs
  -- we are about to draw are non-empty, which is the failure that has actually
  -- happened twice: the bytes of a Private Use Area glyph go missing from a
  -- source file, and an empty icon draws as nothing rather than as an error.
  local icons = require "paseo.ui.icons"
  local blank = {}
  for name, glyph in pairs(icons.all()) do
    if vim.api.nvim_strwidth(glyph) < 1 then
      blank[#blank + 1] = name
    end
  end
  if #blank > 0 then
    table.sort(blank)
    err(
      ("%d glyphs in the icon registry are EMPTY and will draw as nothing: %s"):format(
        #blank,
        table.concat(blank, ", ")
      )
    )
  else
    info(
      ("%d glyphs in the registry, all non-empty -- a Nerd Font is required and "):format(
        vim.tbl_count(icons.all())
      ) .. "cannot be detected from here; if you see boxes, that is the font"
    )
  end

  -- The style, since it is the first thing someone changes and the last thing
  -- they remember changing.
  local style = require("paseo.ui.style").get()
  info(("ui.style: %s cards, %s border"):format(style.card, style.border))
end

local function check_paseo()
  local daemon = require "paseo.daemon"
  start "paseo.nvim: the Paseo daemon"

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

---The bundled agent skills, and whether anything can see them.
---
---THIS SECTION IS THE POINT. The skills only load when an agent's cwd is
---inside this repository, so the projects they describe -- multi-repo
---workspaces -- never see them, and the only way anyone learned they existed
---was by accident. Naming them in the check people already run is the fix;
---the installer is just what you type next.
local function check_skills()
  start "paseo.nvim: agent skills"

  local skills = require "paseo.skills"
  local plugin = require "paseo.plugin"

  local root = plugin.root()
  if not root then
    return err "cannot locate this plugin's own directory; skills cannot be installed"
  end

  local bundled = skills.bundled()
  if #bundled == 0 then
    return err(
      ("no skills found in %s/%s — an archive that dropped dotfiles, or an incomplete install"):format(
        vim.fn.fnamemodify(root, ":~"),
        skills.DIR
      )
    )
  end

  for _, skill in ipairs(bundled) do
    info(("%s — %s"):format(skill.name, (skill.description or ""):sub(1, 70)))
  end

  local dirs = skills.targets "global" or {}
  for _, dir in ipairs(dirs) do
    local short = vim.fn.fnamemodify(dir, ":~")
    local installed, problems = 0, {}
    for _, skill in ipairs(bundled) do
      local at = skills.inspect(skill, dir)
      if at == "ours_link" or at == "ours_copy" then
        installed = installed + 1
      elseif at ~= "absent" then
        problems[#problems + 1] = ("%s: %s"):format(skill.name, at)
      end
    end

    if installed == #bundled then
      ok(("%s — all %d installed"):format(short, installed))
    elseif installed == 0 then
      warn(("%s — none installed; run `:Paseo skills install`"):format(short))
    else
      warn(("%s — %d of %d installed; run `:Paseo skills install`"):format(short, installed, #bundled))
    end
    for _, problem in ipairs(problems) do
      warn(("%s: %s"):format(short, problem))
    end
  end

  -- Said only where it applies. An agent whose cwd is a member worktree reads
  -- project skills from that repo, not from the project root two levels up --
  -- so a project install is invisible to exactly the agent these are for, and
  -- somebody will otherwise reach for it as "the tidier option".
  local project = skills.targets("project")
  if project then
    info(
      "a `project` install lands at "
        .. vim.fn.fnamemodify(project[1] or "?", ":~")
        .. ", which an agent working inside a member worktree does NOT read"
    )
  end
end

function M.check()
  check_core()
  check_paseo()
  check_images()
  check_skills()
end

return M
