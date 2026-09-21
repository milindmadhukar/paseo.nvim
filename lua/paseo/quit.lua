--- Guard Neovim exits while Paseo agent sessions are active.
---
--- Paseo agents belong to the daemon and keep running after Neovim closes.
--- The prompt protects the user's live view; it never stops the daemon.

local M = {}

local prompting = false
local checking = false
local installed = false
local chaining = 0

local function layout_windows()
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      out[#out + 1] = win
    end
  end
  return out
end

---@param command string
---@return boolean
function M.would_exit(command)
  local name = vim.trim(command or ""):match "^(%S+)" or ""
  name = name:gsub("!$", ""):lower()
  if vim.tbl_contains({ "qa", "qall", "quitall", "wqa", "wqall", "xa", "xall" }, name) then
    return true
  end
  if not vim.tbl_contains({ "q", "quit", "wq", "x", "xit", "exit" }, name) then
    return false
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    return false
  end
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    return false
  end
  return #layout_windows() <= 1
end

local function ask(proceed)
  local active = require("paseo.agents").active()
  if #active == 0 then
    return proceed()
  end
  if prompting then
    return
  end
  prompting = true
  local noun = #active == 1 and "agent session is" or "agent sessions are"
  vim.ui.select({ "Quit Neovim", "Cancel" }, {
    prompt = ("%d active Paseo %s still working. Paseo work will continue on the daemon; quitting only closes this Neovim client."):format(
      #active,
      noun
    ),
  }, function(choice)
    prompting = false
    if choice == "Quit Neovim" then
      proceed()
    end
  end)
end

---Run `proceed` unless the user cancels because Paseo work is active.
---@param proceed fun()
---@param opts? { force?: boolean }
function M.guard(proceed, opts)
  opts = opts or {}
  if
    chaining > 0
    or opts.force
    or require("paseo.config").get().quit.warn_active_agents == false
  then
    return proceed()
  end
  local bridge = require "paseo.bridge"
  if not bridge.running() then
    return proceed()
  end
  local agents = require "paseo.agents"
  if agents.ready() then
    return ask(proceed)
  end
  if checking then
    return
  end
  checking = true
  agents.watch(function(err)
    vim.schedule(function()
      checking = false
      if err then
        -- A warning that cannot establish whether work is active must not trap
        -- someone in Neovim. The daemon, not this client, owns that work.
        return proceed()
      end
      ask(proceed)
    end)
  end)
end

---@param command string
function M.request(command)
  command = vim.trim(command or "")
  local force = command:match "!%s*$" ~= nil
  if force or not M.would_exit(command) then
    return vim.cmd(command)
  end
  M.guard(function()
    vim.cmd(command)
  end)
end

local function has_mapping(mode, lhs)
  local mapping = vim.fn.maparg(lhs, mode, false, true)
  return type(mapping) == "table" and next(mapping) ~= nil
end

local function chained(mapping, fallback)
  if not mapping then
    return fallback
  end
  return function()
    chaining = chaining + 1
    local ok, err
    if type(mapping.callback) == "function" then
      ok, err = pcall(mapping.callback)
    elseif type(mapping.rhs) == "string" and mapping.rhs ~= "" then
      ok, err = pcall(
        vim.api.nvim_feedkeys,
        vim.keycode(mapping.rhs),
        mapping.noremap == 1 and "nx" or "mx",
        false
      )
    else
      ok, err = pcall(fallback)
    end
    chaining = chaining - 1
    if not ok then
      vim.notify("paseo: chained quit mapping failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

---Install wrappers for ordinary interactive quit routes without replacing a
---user's command-line abbreviations or normal-mode mappings.
function M.install()
  if installed then
    return
  end
  installed = true

  vim.api.nvim_create_user_command("PaseoQuit", function(args)
    M.request(args.args)
  end, { nargs = 1, complete = "command", desc = "Quit through Paseo's active-agent guard" })

  for _, command in ipairs {
    "q",
    "quit",
    "qa",
    "qall",
    "quitall",
    "wq",
    "wqa",
    "wqall",
    "x",
    "xit",
    "exit",
    "xa",
    "xall",
  } do
    if not has_mapping("c", command) then
      local expression = ("getcmdtype() ==# ':' && getcmdline() ==# '%s' ? 'PaseoQuit %s' : '%s'"):format(
        command,
        command,
        command
      )
      vim.cmd(("cnoreabbrev <expr> %s %s"):format(command, expression))
    end
  end

  for key, command in pairs { ZZ = "xit", ZQ = "quit!" } do
    local existing = vim.fn.maparg(key, "n", false, true)
    existing = type(existing) == "table" and next(existing) ~= nil and existing or nil
    local proceed = chained(existing, function()
      vim.cmd(command)
    end)
    vim.keymap.set("n", key, function()
      if not M.would_exit(command) then
        return proceed()
      end
      -- ZQ's force is its normal built-in meaning. It still warns; only an
      -- explicit `:...!` typed by the user is the lifecycle bypass.
      M.guard(proceed)
    end, {
      silent = existing and existing.silent == 1 or true,
      desc = "paseo: " .. command .. " with active-agent warning",
    })
  end
end

function M.is_prompting()
  return prompting
end

return M
