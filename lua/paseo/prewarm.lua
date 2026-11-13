--- Have the answers before they are asked for.
---
--- The first `:Paseo chat` of a session used to pay for everything at once:
--- booting the sidecar, probing for the daemon, connecting, subscribing to
--- the agent directory, listing the workspaces for the rail -- and the first
--- `<C-n>` for the provider catalogue on top. None of it depends on what you
--- are about to do, so it is done shortly after Neovim starts, off the
--- startup path, while you are still looking at your code.
---
--- ONLY IF A DAEMON IS ALREADY THERE. Starting Neovim must never start a
--- daemon: that is |paseo-config.paseo.autostart|'s call, made when you ask
--- for an agent. So the local daemon is probed first (without blocking), and
--- with no answer nothing else happens. Remote hosts are not dialled at all:
--- a startup that reaches across the network is a startup that can hang on it.
---
--- `paseo.prewarm = false` turns it off.

local M = {}

---@type boolean
local done = false

---Warm the local host: the bridge, the agent directory, the rail's
---workspaces and this directory's provider catalogue.
function M.run()
  if done then
    return
  end
  done = true
  local config = require("paseo.config").get()
  if config.paseo.prewarm == false then
    return
  end
  local hosts = require "paseo.hosts"
  local host = hosts.get(nil)
  if not (host and host.local_host) then
    return
  end
  local bridge = require "paseo.bridge"
  if bridge.running(host.id) then
    return
  end
  require("paseo.daemon").resolve_async(function(endpoint)
    if not endpoint then
      return
    end
    bridge.ensure(function(err)
      if err then
        return
      end
      pcall(require("paseo.agents").watch, nil, host.id)
      -- The rail's list for the project you are standing in: what <C-b>
      -- would fetch on its first show.
      pcall(require("paseo.ui.rail").load)
      -- And what the new-task screen asks for first (|paseo.store|).
      -- Keyed as the screen keys it: where `new.context` says you are.
      local ok, root = pcall(require("paseo.ui.chat").here)
      if ok and root then
        pcall(require("paseo.ui.create").catalogue, root, function() end, host.id)
      end
    end, host.id)
  end)
end

---Forget that it ran (tests).
function M.reset()
  done = false
end

---Run once, a moment after startup has finished: after `VimEnter` (or now,
---if setup ran after it -- a lazy-loaded plugin), plus `delay` ms so the
---first screen is drawn and the first keys answered before any of it starts.
---@param delay? integer ms, default 400
function M.schedule(delay)
  local function later()
    vim.defer_fn(M.run, delay or 400)
  end
  if vim.v.vim_did_enter == 1 then
    return later()
  end
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("paseo.prewarm", { clear = true }),
    once = true,
    callback = later,
  })
end

return M
