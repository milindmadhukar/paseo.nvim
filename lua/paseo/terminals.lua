--- The live terminal directory.
---
--- Paseo owns terminals as well as agents -- the `claude` and `codex` terminal processes
--- you started from the app are PTYs on the daemon, not processes on your
--- machine -- and until now none of them were reachable from here. This is the
--- list half; |paseo.ui.terminal| is the PTY half.
---
--- Shaped deliberately like |paseo.agents|: a table the panel reads
--- synchronously, fed by push. The daemon reports a terminal's `activity`
--- alongside its name, which is what lets the list say which one is waiting on
--- you without polling every one of them.

local bridge = require "paseo.bridge"
local config = require "paseo.config"

local M = {}

---@class paseo.Terminal
---@field id string
---@field name string
---@field title string|nil
---@field workspaceId string|nil
---@field activity { state: string, attentionReason: string|nil, changedAt: number }|nil

---@type table<string, paseo.Terminal>  terminal id -> terminal
local terminals = {}
---The cwd each terminal was listed under. The daemon reports terminals per
---DIRECTORY and does not put the directory on the terminal, so a plugin that
---watches two roots at once needs to remember which list each came from.
---@type table<string, string>
local roots = {}
---Roots already subscribed. Per root rather than a single flag: the daemon
---reports terminals per DIRECTORY, so watching one workspace tells you nothing
---about another, and a plain boolean would make the second dashboard you open
---look empty.
---@type table<string, boolean>
local watched = {}
---Roots a snapshot has actually arrived for. Separate from `watched`, which is
---set BEFORE the round trip so a redraw-driven `watch` cannot queue one
---subscription per frame -- and which therefore says "ready" while the first
---list is still in flight, so a workspace with three terminals in it read as
---"none yet" for as long as the daemon took to answer.
---@type table<string, boolean>
local answered = {}
---Names given here rather than by the daemon.
---
---`renameTerminal` takes a `title`, and `title` is ALSO what the PTY reports
---for itself -- so the daemon overwrites a rename with the shell's own
---`milind@host:~/dir` within a second of you typing one, and every terminal in
---a directory ends up with the same useless label. The name you choose is
---therefore kept here, and the daemon is still told in case a later one keeps
---it. Precedence is floaterm's: a name you gave, then the stable one the
---daemon assigned, then the live title.
---@type table<string, string>
local labels = {}
---`bridge.on` has no `off`, so the directory listener is registered once.
local listening = false
local listeners = {}

---@param payload table
local function apply(payload)
  if payload.kind == "error" then
    vim.notify("paseo: terminal directory: " .. tostring(payload.error), vim.log.levels.WARN)
    if payload.cwd then
      watched[payload.cwd] = nil
    end
    return
  end

  -- `terminals_changed` is a full list FOR ONE CWD, never a delta. Replacing
  -- the whole table would drop every terminal under any other root, so only
  -- the entries belonging to this cwd are cleared before the new ones land.
  local cwd = payload.cwd
  if cwd then
    answered[cwd] = true
    for id, at in pairs(roots) do
      if at == cwd then
        terminals[id] = nil
        roots[id] = nil
      end
    end
  end

  for _, terminal in ipairs(payload.entries or {}) do
    if terminal.id then
      terminals[terminal.id] = terminal
      roots[terminal.id] = cwd
    end
  end

  for _, fn in ipairs(listeners) do
    pcall(fn, terminals)
  end
end

---Start following the terminals under `root`. Safe to call repeatedly.
---@param root string
---@param callback? fun(err: string|nil)
function M.watch(root, callback)
  callback = callback or function() end
  if watched[root] then
    return callback(nil)
  end
  -- Marked before the round trip, not after. `M.lines` calls this on every
  -- redraw, and a dashboard repaints many times before the first response
  -- lands -- so waiting for the answer would queue a subscription per frame.
  watched[root] = true

  bridge.ensure(function(err)
    if err then
      watched[root] = nil
      return callback(err)
    end
    if not listening then
      listening = true
      bridge.on("terminals", apply)
    end
    bridge.request("terminals.watch", { cwd = root }, function(sub_err)
      if sub_err then
        watched[root] = nil
      end
      callback(sub_err)
    end)
  end)
end

---The payload handler, exposed for the spec.
---
---Reaching it any other way means standing up a sidecar and a daemon, which is
---a great deal of machinery to assert that one root's list does not clobber
---another's.
M._apply = apply

---Seed a terminal the daemon has just made, under the root it was made in.
---
---The directory is told by PUSH, and `terminals.create` answers before the
---snapshot carrying the new terminal arrives -- so opening the thing you just
---created would otherwise have to wait for a round trip that has already
---happened once. The snapshot replaces this the moment it lands.
---@param terminal paseo.Terminal
---@param root string
function M.adopt(terminal, root)
  if not (terminal and terminal.id) then
    return
  end
  terminals[terminal.id] = terminal
  roots[terminal.id] = root
end

---Call `fn` whenever the list changes.
---@param fn fun(terminals: table<string, paseo.Terminal>)
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

---What to call a terminal. See `labels`.
---@param terminal paseo.Terminal|string  A terminal, or its id.
---@return string
function M.label(terminal)
  if type(terminal) == "string" then
    terminal = terminals[terminal] or { id = terminal }
  end
  if type(terminal) ~= "table" or not terminal.id then
    return "?"
  end
  return labels[terminal.id] or terminal.name or terminal.title or terminal.id
end

---The live title the PTY reports for itself -- the shell's prompt title,
---usually `user@host:~/dir`. Worth showing where there is room for it, and
---never in a twenty-column rail where every terminal's is identical.
---@param terminal paseo.Terminal
---@return string|nil
function M.subtitle(terminal)
  local title = terminal and terminal.title
  if not title or title == "" or title == M.label(terminal) then
    return nil
  end
  return title
end

---@param id string
---@param label string|nil  nil or empty hands the name back to the daemon's.
function M.set_label(id, label)
  if not id then
    return
  end
  labels[id] = (label and vim.trim(label) ~= "") and vim.trim(label) or nil
  for _, fn in ipairs(listeners) do
    pcall(fn, terminals)
  end
end

---@param id string
---@return paseo.Terminal|nil
function M.get(id)
  return terminals[id]
end

---Terminals listed under `root`, in a stable order.
---@param root string
---@return paseo.Terminal[]
function M.for_root(root)
  root = vim.fn.resolve(vim.fn.fnamemodify(root, ":p")):gsub("/+$", "")
  local out = {}
  for id, terminal in pairs(terminals) do
    local at = roots[id]
    if at then
      at = vim.fn.resolve(at):gsub("/+$", "")
    end
    if at == root or (at and vim.startswith(at, root .. "/")) then
      out[#out + 1] = terminal
    end
  end
  table.sort(out, function(a, b)
    return M.label(a) < M.label(b)
  end)
  return out
end

---Whether the directory has answered yet, so the panel can say "loading"
---rather than "none" before the first list lands.
---@return boolean
function M.ready(root)
  root = vim.fn.resolve(vim.fn.fnamemodify(root, ":p")):gsub("/+$", "")
  for cwd, yes in pairs(answered) do
    if yes then
      local at = vim.fn.resolve(cwd):gsub("/+$", "")
      if at == root or vim.startswith(at, root .. "/") then
        return true
      end
    end
  end
  return false
end

---How a terminal's activity draws, as { glyph, highlight group }.
---@param terminal paseo.Terminal
---@return string[]
function M.glyph(terminal)
  local activity = terminal.activity
  local state = activity and activity.state
  local icons = require "paseo.ui.icons"
  if state == "attention" then
    return { icons.status.permission, "PaseoDanger" }
  elseif state == "working" then
    return { icons.status.running, "PaseoAgent" }
  end
  return { icons.status.idle, "PaseoDim" }
end

---A one-line summary of a root's terminals, for a picker column.
---@param root string
---@return string
function M.summary(root)
  local list = M.for_root(root)
  if #list == 0 then
    return watched[root] and "" or "…"
  end

  local attention, working = 0, 0
  for _, terminal in ipairs(list) do
    local state = terminal.activity and terminal.activity.state
    if state == "attention" then
      attention = attention + 1
    elseif state == "working" then
      working = working + 1
    end
  end

  if attention > 0 then
    return ("! %d needs you"):format(attention)
  end
  if working > 0 then
    return ("· %d running"):format(working)
  end
  return ("%d idle"):format(#list)
end

-- ---------------------------------------------------------------- the verbs

---A redraw of whatever surface is showing terminals, if any.
---
---The directory has no idea what is drawing it, and should not: `float` is the
---only surface left that does, and it answers a no-op when it is shut.
local function repaint()
  vim.schedule(function()
    pcall(function()
      require("paseo.ui.float").rebuild()
    end)
  end)
end

---Everything `c` can start: a shell, then one entry per provider the daemon
---actually has, then whatever is configured, then a free-text escape hatch.
---
---The providers are read LIVE, so enabling one in Paseo makes it appear here
---without a config change. The filter is `enabled ~= false` rather than
---`status == "ready"`: a provider can be installed and configured while its
---models are still being fetched, and a terminal running its CLI does not need
---a model at all.
---@param cwd string
---@param callback fun(presets: table[])
function M.presets(cwd, callback)
  local out = { { label = "Shell", note = "$SHELL on the daemon's host" } }

  for _, preset in ipairs(config.get().ui.terminal.presets or {}) do
    if type(preset) == "string" then
      out[#out + 1] = { label = preset, command = preset }
    elseif type(preset) == "table" and preset.command then
      out[#out + 1] = {
        label = preset.label or preset.command,
        command = preset.command,
        args = preset.args,
      }
    end
  end
  out[#out + 1] = { label = "Command…", prompt = true, note = "type one" }

  require("paseo.ui.create").catalogue(cwd, function(entries)
    local providers = {}
    for _, entry in ipairs(entries or {}) do
      if entry.enabled ~= false and entry.provider then
        providers[#providers + 1] = {
          label = entry.label or entry.provider,
          command = entry.provider,
          note = entry.provider,
        }
      end
    end
    -- Providers go after the shell and before everything else, which is the
    -- order you reach for them in.
    for i, preset in ipairs(providers) do
      table.insert(out, i + 1, preset)
    end
    callback(out)
  end)
end

---Start a terminal in `cwd`.
---
---Nothing checks that the command exists, on purpose: the terminal runs on the
---DAEMON's host, which is not necessarily this machine, so the honest failure
---is the PTY printing `command not found`.
---@param cwd string
---@param preset table  `{ command?, args?, label? }`
---@param size { rows: integer, cols: integer }
---@param callback fun(id: string|nil, err: string|nil)
function M.create(cwd, preset, size, callback)
  preset = preset or {}
  require("paseo.bridge").request("terminals.create", {
    cwd = cwd,
    command = preset.command,
    args = preset.args,
    name = preset.label ~= "Shell" and (preset.label or preset.command) or nil,
    rows = size and size.rows or 24,
    cols = size and size.cols or 80,
  }, function(err, result)
    vim.schedule(function()
      if err then
        return callback(nil, tostring(err))
      end
      local item = result and result.terminal
      if not (item and item.id) then
        return callback(nil, "the daemon started no terminal")
      end
      -- The directory is told by push and may not have caught up, so seed it
      -- rather than waiting for the snapshot.
      M.adopt(item, cwd)
      if preset.label and preset.label ~= "Shell" then
        M.set_label(item.id, preset.label)
      end
      callback(item.id, nil)
    end)
  end)
end

---@param id string
function M.rename(id)
  local item = M.get(id)
  vim.ui.input({ prompt = "Name: ", default = item and M.label(item) or "" }, function(title)
    if title == nil then
      return
    end
    -- Ours first, because it is the one that survives. `renameTerminal` sets
    -- the daemon's `title`, and `title` is also what the PTY reports for
    -- itself -- so the shell overwrites your name with `user@host:~/dir`
    -- within a second, and every terminal in one directory ends up labelled
    -- identically. The daemon is told anyway, because a later one may keep
    -- it and the name then shows up in the Paseo app too; nothing here waits
    -- on that answer.
    M.set_label(id, title)
    repaint()
    require("paseo.bridge").request(
      "terminals.rename",
      { terminalId = id, title = title },
      function() end
    )
  end)
end

---@param id string
function M.kill(id)
  local item = M.get(id)
  local name = item and M.label(item) or id
  -- Killing a terminal kills whatever is running in it, and "whatever" is
  -- routinely an agent mid-turn. Asked rather than assumed.
  vim.ui.select({ "no", "yes" }, { prompt = ("Kill %s?"):format(name) }, function(choice)
    if choice ~= "yes" then
      return
    end
    require("paseo.bridge").request("terminals.kill", { terminalId = id }, function(err)
      if err then
        vim.schedule(function()
          vim.notify("paseo: could not kill it — " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    end)
  end)
end

return M
