--- The `local` backend: an agent in a terminal, driven by `nvim_chan_send`.
---
--- Exists so the plugin is installable without Paseo, and so a sidecar that
--- cannot start is a degradation rather than an outage. Worktree assembly and
--- the whole review layer are ours regardless, so this costs little.
---
--- It is strictly worse than the Paseo backend and is not the default: there is
--- no streaming (the reply stays in the terminal), no agent-session reuse across
--- Neovim restarts, and prompts go in as keystrokes -- which is the one place
--- bracketed paste matters.

local M = {}

---@type table<string, integer>  worktree -> floaterm buffer
local terminals = {}

---Send text to a terminal as if pasted.
---
---BRACKETED PASTE is why this is not a plain `nvim_chan_send`. A TUI in
---bracketed-paste mode reads the `\27[200~` / `\27[201~` wrapper as "this is
---one paste, not typing", so a multi-line prompt arrives as a block instead of
---the TUI acting on each newline -- which, in an agent REPL, means submitting
---the first line and typing the rest into whatever appears next.
---@param chan integer
---@param text string
local function paste(chan, text)
  vim.api.nvim_chan_send(chan, "\27[200~" .. text .. "\27[201~")
  -- Submit separately and afterwards: inside the paste wrapper a carriage
  -- return is literal text, not "run it".
  vim.defer_fn(function()
    pcall(vim.api.nvim_chan_send, chan, "\r")
  end, 50)
end

---@param repo paseo.Repo
---@return integer|nil chan
local function terminal_for(repo)
  local buf = terminals[repo.worktree]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    -- floaterm starts its job lazily (`utils.lua:179`), so a terminal created
    -- hidden has no job yet and `terminal_job_id` is nil. Not an error; just
    -- not ready.
    return vim.b[buf].terminal_job_id
  end
  return nil
end

---Open (or reuse) the agent terminal for a repo.
---@param repo paseo.Repo
---@param command string
---@return integer|nil chan
function M.open(repo, command)
  local ok, api = pcall(require, "floaterm.api")
  if not ok then
    vim.notify("paseo: the local backend needs floaterm", vim.log.levels.ERROR)
    return nil
  end

  local existing = terminal_for(repo)
  if existing then
    return existing
  end

  -- floaterm runs `$SHELL -c "<cmd>; $SHELL"` (`utils.lua:28`), so a `cd` in
  -- the command gives this terminal its own cwd without forking floaterm.
  local term = api.new_term {
    name = "paseo:" .. repo.name,
    cmd = ("cd %s && %s"):format(vim.fn.shellescape(repo.worktree), command),
  }
  if term and term.buf then
    terminals[repo.worktree] = term.buf
  end
  return terminal_for(repo)
end

---Send a prompt to the repo's agent terminal.
---@param repo paseo.Repo
---@param prompt string
---@param opts? { command?: string }
---@return boolean sent
function M.send(repo, prompt, opts)
  opts = opts or {}
  local chan = M.open(repo, opts.command or "claude")
  if not chan then
    vim.notify("paseo: the agent terminal is not ready yet; try again", vim.log.levels.WARN)
    return false
  end
  paste(chan, prompt)
  return true
end

return M
