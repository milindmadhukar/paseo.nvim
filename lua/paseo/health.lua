--- `:checkhealth paseo`
---
--- Split into hard requirements (the review layer), and the Paseo backend
--- (which degrades to the `local` backend rather than breaking anything).

local config = require "paseo.config"

local M = {}

local start, ok, warn, err, info =
  vim.health.start, vim.health.ok, vim.health.warn, vim.health.error, vim.health.info

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
  start "paseo.nvim: Paseo backend"

  if cfg.backend ~= "paseo" then
    info(('backend is "%s"; the Paseo checks below are informational'):format(cfg.backend))
  end

  local cli = version_of(cfg.paseo.cli)
  if cli then
    ok(("`%s` -> %s"):format(cfg.paseo.cli, cli))
    info "the CLI is for one-shot writes only (~2.4s/call); no interactive path uses it"
  else
    warn(
      ("`%s` is not executable; one-shot writes and the CLI fallback are unavailable"):format(
        cfg.paseo.cli
      )
    )
  end

  -- The daemon, over plain HTTP. This is the only REST endpoint that exists --
  -- everything else 404s -- so it is a liveness probe and nothing more.
  if vim.fn.executable "curl" == 1 then
    local probe = { "curl", "-s", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}" }
    probe[#probe + 1] = cfg.paseo.health_url
    local res = vim.system(probe, { text = true }):wait()
    if (res.stdout or ""):match "^2%d%d$" then
      ok(("daemon is up (%s)"):format(cfg.paseo.health_url))
    else
      local fix = "daemon is not answering at %s -- try `%s daemon start`"
      warn(fix:format(cfg.paseo.health_url, cfg.paseo.cli))
    end
  else
    info "`curl` not found; skipped the daemon liveness probe"
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

  info(("agent transport: %s"):format(cfg.paseo.url))
end

function M.check()
  check_core()
  check_paseo()
end

return M
